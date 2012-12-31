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

our @expressions;

BEGIN {
    unshift(@INC, File::Spec->catfile($Bin, File::Spec->updir(), 'inc'));
    eval "use load_calculator_expressions;";
    @expressions =  load_calculator_expressions->new()->load(File::Spec->catfile($Bin, File::Spec->updir(), 'data', 'calculator.txt'));
    plan tests => 1 + scalar(@expressions);
}

use MarpaX::Import;
ok(1);

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

my $any = MarpaX::Import->new();

open(GRAMMAR, '<', File::Spec->catfile($Bin, File::Spec->updir(), 'data', 'calculator_rank.ebnf')) || die "Cannot open calculator_rank.ebnf, $!\n";
my $data = do { local $/; <GRAMMAR> };
close(GRAMMAR);

my $grammar = $any->grammar($data);
my $closures = {
    do_factor => sub {shift; return $_[0]+0},
    do_parens => sub {shift; return $_[1]},
    do_pow    => sub {shift; return $_[0] ** $_[2]},
    do_mul    => sub {shift; return $_[0] * $_[2]},
    do_div    => sub {shift; return $_[0] / $_[2]},
    do_add    => sub {shift; return $_[0] + $_[2]},
    do_sub    => sub {shift; return $_[0] - $_[2]}
};
foreach (@expressions) {
    ok($any->recognize($grammar, $_, $closures), eval $_);
}
