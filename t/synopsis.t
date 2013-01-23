#!/usr/bin/perl
use strict;
use diagnostics;
use MarpaX::Import;
use FindBin qw/$Bin/;
use Test;
use Log::Log4perl qw /:easy/;
use Log::Any::Adapter;

Log::Log4perl::init(File::Spec->catfile($Bin, 'log4perl.conf'));
Log::Any::Adapter->set('Log4perl');

BEGIN {
    plan tests => 1;
}

my $ebnf = MarpaX::Import->new();
$ebnf->startrules([qw/Expression/]);
my $grammar = $ebnf->grammar(<<'END_OF_RULES'
Expression ::=
     qr/[[:digit:]]+/             action => do_number
     | '(' Expression ')'         action => do_parens   assoc => group
    || Expression '**' Expression action => do_pow      assoc => right
    || Expression '*' Expression  action => do_multiply
     | Expression '/' Expression  action => do_divide
    || Expression '+' Expression  action => do_add
     | Expression '-' Expression  action => do_subtract
END_OF_RULES
    );
my $closures = {
    do_number    => sub {shift; return int($_[0]);},
    do_parens    => sub {shift; return $_[1];},
    do_pow       => sub {shift; return $_[0] ** $_[2];},
    do_multiply  => sub {shift; return $_[0] * $_[2];},
    do_divide    => sub {shift; return $_[0] / $_[2];},
    do_add       => sub {shift; return $_[0] + $_[2];},
    do_subtract  => sub {shift; return $_[0] - $_[2];},
    do_first_arg => sub {shift; return $_[0];}
};
my $string = '42 * 2 + 7 / 3';
ok(${$ebnf->recognize($grammar, $string, $closures)}, eval $string);
