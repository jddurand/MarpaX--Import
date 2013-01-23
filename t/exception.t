#!/usr/bin/perl
use strict;
use warnings;
use File::Spec;
use FindBin qw/$Bin/;
use Test;
use Log::Log4perl qw /:easy/;
use Log::Any::Adapter;

Log::Log4perl::init(File::Spec->catfile($Bin, 'log4perl.conf'));
Log::Any::Adapter->set('Log4perl');

our @results;

BEGIN {
    @results = (
        # Data       # ${$value}
	[ 'ok'     , 'ok' ],
	[ 'notok'  , undef ],
	[ 'unknown', undef ],
	);
    plan tests => 1 + scalar(@results);
}

use MarpaX::Import;
ok(1);

my $any = MarpaX::Import->new();
open(GRAMMAR, '<', File::Spec->catfile($Bin, File::Spec->updir(), 'data', 'exception.ebnf')) || die "Cannot open exception.ebnf, $!\n";
my $data = do { local $/; <GRAMMAR> };
close(GRAMMAR);

my $grammar = $any->grammar($data);
foreach (@results) {
    my ($data, $wanted) = @{$_};
    my $rc = $any->recognize($grammar, $data);
    ok(${$rc}, $wanted);
}
