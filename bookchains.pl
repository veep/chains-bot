#!/usr/bin/env perl

use common::sense;
use FindBin;
use lib "$FindBin::Bin/cpan/lib/perl5";
use IO::All qw/io/;
use File::Basename qw/fileparse/;
use JSON::PP;

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

    post_item($state);
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
        DEBUG('http get',$results);
        my $parsed_results = decode_json $results;
        if ($parsed_results->{num_found} > 0) {
            my $seed = cleanup_item($parsed_results->{docs}[0]);
            DEBUG('clean object', $seed);
            return $seed;
        }
    }
    die "There are no unused seeds, and it's seed time\n";
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
sub item_validates { return 1;}
sub post_item {}

sub DEBUG {
    use Data::Dump;
    if ($DEBUG) {
        ddx [@_];
    }
}
