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

BEGIN {
    plan tests => 2;
}

use MarpaX::Import;
ok(1);
my $any = MarpaX::Import->new();
open(GRAMMAR, '<', File::Spec->catfile($Bin, File::Spec->updir(), 'data', 'bnf.bnf')) || die "Cannot open bnf.bnf, $!\n";
my $data = do { local $/; <GRAMMAR> };
close(GRAMMAR);

$any->startrules([qw/syntax/]);
my $grammar = $any->grammar($data);
ok(defined($grammar));
