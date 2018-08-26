#!/usr/bin/env perl

use common::sense;
use FindBin;
use lib "$FindBin::Bin/cpan/lib/perl5";

use File::Basename qw/fileparse/;
use File::Temp qw/ tempfile /;
use IO::All qw/io/;
use JSON::PP;
use List::Util qw/shuffle/;
use Mastodon::Client;
use sort 'stable';

my $DEBUG = 1;

my $SKIP_TOOT = 0;

main();
sub main {
    my $state = load_state();
    $state->{connections} //= [];
    $state->{covers_seen} //= {};

    if (my $reason = should_we_exit($state)) {
        warn "Exiting without posting:\n$reason\n";
        exit 1;
    }

    my $next_item;
    do {
        if (seed_is_due($state)) {
            $next_item = validated_seed($state);
        } else {
            $next_item = next_from_state($state);
        }
    } until item_validates($next_item);

    post_item($state, $next_item);
    save_state($state);
}




sub state_file {
    my ($name,$path,$suffix) = fileparse($0,'.pl');
    return join('',$path,$name,'.state');
}

sub load_state {
    my $filename = state_file();
    if (-r $filename) {
        my $state = decode_json scalar io->file($filename)->slurp;
        DEBUG('read state',$state);
        return $state;
    }
    return {};
}
sub save_state {
    my ($state) = @_;
    my $filename = state_file();
    if (-w $filename) {
        encode_json $state > io($filename);
    }
}

sub seed_is_due {
    my $state = shift;
    return $state->{seed_is_due};
}
sub should_we_exit {
    my $state = shift;
    return 0;
}
sub validated_seed {
    my $state = shift;
    while (
        $state->{unused_seeds} &&
        ref $state->{unused_seeds} eq 'ARRAY' and
        @{$state->{unused_seeds}}
    ) {
        my $seed_id = shift @{$state->{unused_seeds}};
        push @{$state->{used_seeds}}, $seed_id;
        my $parsed_results;
        eval {
            my $results < io('http://openlibrary.org/search.json?q=' . $seed_id);
            #        DEBUG('http get',$results);
            $parsed_results = decode_json $results;
        };
        if ($@) {
            DEBUG("Skipping $seed_id",$@);
            next;
        }
        if ($parsed_results->{num_found} > 0) {
            my $seed = cleanup_item($parsed_results->{docs}[0]);
            $seed = mark_as_seed($seed);
#            DEBUG('clean object', $seed);
            if (item_validates($seed)) {
                $state->{seed_is_due} = 0;
                $state->{chain_length} = 0;
                return $seed;
            }
        }
    }
    die "There are no unused seeds, and it's seed time\n";
}

sub mark_as_seed {
    my $item = shift;
    $item->{is_seed} = 1;
    return $item;
}

sub cleanup_item {
    my $item = shift;
    my $new_item = {};

    my @copy_keys = (
        qw(
              title_suggest publisher edition_key
              author_name subject first_publish_year publish_year first_publish_date
              publish_date author_key type place language cover_edition_key
      ));
    for my $key (@copy_keys) {
        if (exists $item->{$key}) {
            $new_item->{$key} = $item->{$key};
        }
    }
    return $new_item;
}


sub next_from_state {
    my ($state) = @_;
    my @connections = shuffle(
        qw(
              author year title place publisher subject
      ));
    my %weights;
    for my $connection_number (0..2) {
        if ($state->{connections}[$connection_number]) {
            $weights{$state->{connections}[$connection_number]} = 10-$connection_number;
        }
    }
    @connections = sort { ($weights{$a} // 0) <=> ($weights{$b} // 0)} @connections;
    DEBUG('connections order', \@connections);
    for my $connection (@connections) {
        if ($connection eq 'author'
            || $connection eq 'subject'
            || $connection eq 'publisher'
            || $connection eq 'place'
        ) {
            DEBUG("trying to use '$connection'");
            my $key = $connection;
            $key = 'author_key' if $connection eq 'author';
            my $search_key = $connection;
            next unless ref($state->{last_item}{$key}) eq 'ARRAY';
            for my $list_item (@{$state->{last_item}{$key}}) {
                DEBUG("trying $connection",$list_item);
                my $results < io('http://openlibrary.org/search.json?'
                                 . $search_key . '=' . $list_item);
                my $parsed_results = decode_json $results;
                DEBUG("number found",$parsed_results->{num_found});
                if ($parsed_results->{num_found} > 1) {
                    my @books = shuffle @{$parsed_results->{docs}};
                    for my $book (@books) {
                        next if $state->{covers_seen}{$book->{cover_edition_key}};
                        if (item_validates($book)) {
                            unshift(@{$state->{connections}},$connection);
                            $state->{connection_value} = $list_item;
                            return $book;
                        }
                    }
                }
            }
        } elsif ($connection eq 'year') {
            DEBUG("trying to use '$connection'");
            my $key = 'first_publish_year';
            if ($state->{last_item}{$key}) {
                DEBUG("trying $connection",$state->{last_item}{$key});
                my $results < io('http://openlibrary.org/search.json?'
                                 . 'q=' . $state->{last_item}{$key});
                my $parsed_results = decode_json $results;
                DEBUG("number found",$parsed_results->{num_found});
                if ($parsed_results->{num_found} > 1) {
                    my @books = shuffle @{$parsed_results->{docs}};
                    for my $book (@books) {
                        next if $state->{covers_seen}{$book->{cover_edition_key}};
                        next unless $book->{$key} eq $state->{last_item}{$key};
                        if (item_validates($book)) {
                            unshift(@{$state->{connections}},$connection);
                            $state->{connection_value} = $state->{last_item}{$key};
                            return $book;
                        }
                    }
                }
            }
        } elsif ($connection eq 'title') {
            DEBUG("trying to use '$connection'");
            my $title_text = ($state->{last_item}{title_suggest} // $state->{last_item}{title});
            DEBUG("trying $connection",$title_text);
            for my $word (shuffle (lc($title_text) =~ /(\w+)/g)) {
                DEBUG("trying word",$word);
                my $results < io('http://openlibrary.org/search.json?'
                                 . 'q=' . $word);
                my $parsed_results = decode_json $results;
                DEBUG("number found",$parsed_results->{num_found});
                next if $parsed_results->{num_found} > 50000;
                if ($parsed_results->{num_found} > 1) {
                    my @books = shuffle @{$parsed_results->{docs}};
                    for my $book (@books) {
                        next if $state->{covers_seen}{$book->{cover_edition_key}};
                        next unless $book->{title_suggest};
                        DEBUG('checking title',$book->{title_suggest});
                        next unless $book->{title_suggest} =~ /\b$word\b/i;
                        if (item_validates($book)) {
                            unshift(@{$state->{connections}},$connection);
                            $state->{connection_value} = $word;
                            return $book;
                        }
                    }
                }
            }
        }
        DEBUG("failed to use $connection");
    }
    # We're giving up
    $state->{chain_length} = 0;
    $state->{seed_is_due} = 1;
    return {};
}

sub item_validates {
    my $item = shift;
    if (! exists $item->{cover_edition_key}) {
        return 0;
    }
    if (ref($item->{language}) eq 'ARRAY') {
        if (! grep {$_ eq 'eng'} @{$item->{language}}) {
            DEBUG('Bad Languages',$item->{language});
            return 0;
        }
    } else {
        DEBUG('missing language');
        return 0;
    }
    if (! exists $item->{cover_image}) {
        my $url = 	'http://covers.openlibrary.org/b/olid/'
        . $item->{cover_edition_key}
        . '-M.jpg';
        DEBUG('cover image',$url);
        my $image < io($url );
        DEBUG('image length',length($image));
        $item->{cover_image} = $image;
    }
    if (length($item->{cover_image}) < 1000) {
        return 0;
    }
    DEBUG("validated");
    return 1;
}

sub post_item {
  my ($state, $item) = @_;
  my $filename = "./tempfile";
  $item->{cover_image} > io($filename);

  my $secrets = decode_json scalar io->file('secrets.json')->slurp;
  my $client_id = $secrets->{client_id};
  my $client_secret = $secrets->{client_secret};
  my $access_token = $secrets->{access_token};

  my $client;
  if (! $SKIP_TOOT) {
      $client = Mastodon::Client->new
      (
          instance        => 'botsin.space',
          name            => 'BookChains',
          client_id       => $client_id,
          client_secret   => $client_secret,
          access_token    => $access_token,
          coerce_entities => 0,
      );
  }
  my $title_text = ($item->{title_suggest} // $item->{title});
  my $media_id;
  if (! $SKIP_TOOT) {
      $media_id= $client->upload_media(
          $filename,
          "Cover image for '$title_text' from openlibrary.org",
          '0,1'
      );
      DEBUG('media_id',$media_id);
  }
  my ($text,$status,@reply);
  if ($item->{is_seed}) {
      $text = "Let's start a new chain with '" . $title_text . "'\n";
  } else {
      my $shared_text;
      if ($state->{connections}[0] eq 'author') {
          $shared_text = 'a shared author';
      } elsif ($state->{connections}[0] eq 'title') {
          $shared_text = "the shared title word '" . $state->{connection_value} ."'";
      } else {
          $shared_text = "the shared " . $state->{connections}[0] . " '" . $state->{connection_value} ."'";
      }
      $text = "Let's continue the chain from '" .
      ( $state->{last_item}{title_suggest} // $state->{last_item}{title}) .
      "', via " . $shared_text . ".\nNext up is '"
      . $title_text . "'\n";
      @reply = (in_reply_to_id => $state->{last_item_id});
  }
  $text .= 'by ' . join(' & ',@{$item->{author_name}}) . "\n";
  if (! $SKIP_TOOT) {
      if ($text && $media_id->{id}) {
          $status = $client->post_status
          (
              $text,
              {
                  visibility => 'public',
                  media_ids => [$media_id->{id}],
                  @reply,
              }
          );
          #          DEBUG('return status',$status);
      }
  } else {
      use Data::Dump qw/ddx/;
      ddx ['Would have posted',$text];
      $status = { id => rand(1000000) };
  }

  delete $item->{cover_image};  # No need to save this
  if ($status && $status->{id}) {
      $state->{last_item} = $item;
      $state->{last_item_id} = '' . $status->{id};
      $state->{chain_length}++;
      if ($state->{chain_length} >= $state->{max_chain_length}) {
          $state->{chain_length} = 0;
          $state->{seed_is_due} = 1;
      }
      $state->{covers_seen}{$item->{cover_edition_key}} = scalar time;
  }
}

sub DEBUG {
    use Data::Dump qw/dd/;
    if ($DEBUG) {
        dd [@_];
    }
}
