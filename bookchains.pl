#!/usr/bin/env perl

use common::sense;
use FindBin;
use lib "$FindBin::Bin/cpan/lib/perl5";

use File::Basename qw/fileparse/;
use File::Temp qw/ tempfile /;
use IO::All qw/io/;
use JSON::PP;
use Mastodon::Client;

my $DEBUG = 1;

main();
sub main {
    my $state = load_state();

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
    save_state($state, $next_item);
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
sub save_state {}

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
        my $results < io('http://openlibrary.org/search.json?q=' . $seed_id);
#        DEBUG('http get',$results);
        my $parsed_results = decode_json $results;
        if ($parsed_results->{num_found} > 0) {
            my $seed = cleanup_item($parsed_results->{docs}[0]);
            $seed = mark_as_seed($seed);
#            DEBUG('clean object', $seed);
            if (item_validates($seed)) {
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


sub next_from_state {}
sub item_validates {
    my $item = shift;
    if (! exists $item->{cover_edition_key}) {
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

  my $client = Mastodon::Client->new
    (
     instance        => 'botsin.space',
     name            => 'BookChains',
     client_id       => $client_id,
     client_secret   => $client_secret,
     access_token    => $access_token,
     coerce_entities => 0,
    );
  my $media_id= $client->upload_media($filename);
  DEBUG('media_id',$media_id);
  my $text;
  if ($item->{is_seed}) {
    $text = "Let's start a new chain with '" .
      ($item->{title_suggest} // $item->{title}) . "'\n";
    $text .= 'by ' . join(' & ',@{$item->{author_name}}) . "\n";
    if ($text && $media_id->{id}) {
      my $status = $client->post_status
	(
	 $text,
	 {
	  visibility => 'unlisted',
	  media_ids => [$media_id->{id}],
	 }
	);
      DEBUG('return status',$status);
    }
  }
}

sub DEBUG {
    use Data::Dump qw/dd/;
    if ($DEBUG) {
        dd [@_];
    }
}
