#!/usr/bin/perl
# Copyright 2013 Jeffrey Kegler
# This file is part of Marpa::R2.  Marpa::R2 is free software: you can
# redistribute it and/or modify it under the terms of the GNU Lesser
# General Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Marpa::R2 is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser
# General Public License along with Marpa::R2.  If not, see
# http://www.gnu.org/licenses/.

# Various that share a calculator semantics

use 5.010;
use strict;
use warnings;
use Test::More tests => 5;
use English qw( -no_match_vars );
use Scalar::Util qw(blessed);
use MarpaX::Import;
use Log::Log4perl qw /:easy/;
use Log::Any::Adapter;
use FindBin qw/$Bin/;

Log::Log4perl::init(File::Spec->catfile($Bin, File::Spec->updir, 'log4perl.conf'));
Log::Any::Adapter->set('Log4perl');

## no critic (ErrorHandling::RequireCarping);

my $any = MarpaX::Import->new();
my $calculator_grammar = $any->grammar("
:default ::= action => ::array bless => ::lhs
:start ::= Script
Script ::= Expression+ separator => comma bless => script
comma ~ [,]
Expression ::=
    Number bless => primary
    | ('(') Expression (')') assoc => group bless => parens mask => [0,1,0]
   || Expression ('**') Expression assoc => right bless => power mask => [1,0,1]
   || Expression ('*') Expression bless => multiply mask => [1,0,1]
    | Expression ('/') Expression bless => divide mask => [1,0,1]
   || Expression ('+') Expression bless => add mask => [1,0,1]
    | Expression ('-') Expression bless => subtract mask => [1,0,1]
Number ~ [\\d]+

:discard ~ whitespace
whitespace ~ [\\s]+
# allow comments
:discard ~ <hash comment>
<hash comment> ~ <terminated hash comment> | <unterminated
   final hash comment>
<terminated hash comment> ~ '#' <hash comment body> <vertical space char>
<unterminated final hash comment> ~ '#' <hash comment body>
<hash comment body> ~ <hash comment char>*
<vertical space char> ~ [\\x{A}\\x{B}\\x{C}\\x{D}\\x{2028}\\x{2029}]
<hash comment char> ~ [^\\x{A}\\x{B}\\x{C}\\x{D}\\x{2028}\\x{2029}]
",
				       {   bless_package => 'My_Nodes' });

do_test('Calculator 1', $calculator_grammar,
'42*2+7/3, 42*(2+7)/3, 2**7-3, 2**(7-3)' => qr/\A 86[.]3\d+ \s+ 126 \s+ 125 \s+ 16\z/xms);
do_test('Calculator 2', $calculator_grammar,
       '42*3+7, 42 * 3 + 7, 42 * 3+7' => qr/ \s* 133 \s+ 133 \s+ 133 \s* /xms);
do_test('Calculator 3', $calculator_grammar,
       '15329 + 42 * 290 * 711, 42*3+7, 3*3+4* 4' =>
            qr/ \s* 8675309 \s+ 133 \s+ 25 \s* /xms);

my $priority_grammar = <<'END_OF_GRAMMAR';
:default ::= action => ::array
:start ::= statement
statement ::= (<say keyword>) expression bless => statement mask => [0,1] rank => 1
    | expression bless => statement
expression ::=
    number bless => primary
   | variable bless => variable
   || sign expression bless => unary_sign
   || expression ('+') expression bless => add mask => [1,0,1]
number ~ [\d]+
variable ~ qr/[[:alpha:]][[:alnum:]]*/

# Marpa::R2::Display
# name: SLIF DSL synopsis

# :lexeme ~ <say keyword> priority => 1

# Marpa::R2::Display::End

<say keyword> ~ 'say'
sign ~ [+-]
:discard ~ whitespace
whitespace ~ [\s]+
END_OF_GRAMMAR

do_test(
    'Priority test 1',
    $any->grammar($priority_grammar, 
		  {   bless_package => 'My_Nodes' }),
    'say + 42' => qr/ 42 /xms
);

(my $priority_grammar2 = $priority_grammar) =~ s/\brank\s*=>\s*1\b$/rank => -1/xms;
do_test(
    'Priority test 2',
    $any->grammar($priority_grammar2, 
		  {   bless_package => 'My_Nodes' }),
    'say + 42' => qr/ 41 /xms
);

sub do_test {
    my ( $name, $grammar, $input, $output_re, $args ) = @_;

    my $value_ref = $any->recognize($grammar, $input);
    if ( not defined $value_ref ) {
        die "No parse was found, after reading the entire input\n";
    }
    my $parse = { variables => { say => -1 } };
    my $value = ${$value_ref}->doit($parse);
    Test::More::like( $value, $output_re, $name );
}

sub My_Nodes::script::doit {
    my ($self, $parse) = @_;
    return join q{ }, map { $_->doit($parse) } @{$self};
}
sub My_Nodes::statement::doit {
    my ($self, $parse) = @_;
    return $self->[0]->doit($parse);
}

sub My_Nodes::add::doit {
    my ($self, $parse) = @_;
    my ( $a, $b ) = @{$self};
    return $a->doit($parse) + $b->doit($parse);
}

sub My_Nodes::subtract::doit {
    my ($self, $parse) = @_;
    my ( $a, $b ) = @{$self};
    return $a->doit($parse) - $b->doit($parse);
}

sub My_Nodes::multiply::doit {
    my ($self, $parse) = @_;
    my ( $a, $b ) = @{$self};
    return $a->doit($parse) * $b->doit($parse);
}

sub My_Nodes::divide::doit {
    my ($self, $parse) = @_;
    my ( $a, $b ) = @{$self};
    return $a->doit($parse) / $b->doit($parse);
}

sub My_Nodes::unary_sign::doit {
    my ($self, $parse) = @_;
    my ( $sign, $expression ) = @{$self};
    my $unsigned_result = $expression->doit($parse);
    return $sign eq '+' ? $unsigned_result : -$unsigned_result;
} ## end sub My_Nodes::unary_sign::doit

sub My_Nodes::variable::doit {
    my ( $self, $parse ) = @_;
    my $name = $self->[0];
    Marpa::R2::Context::bail(qq{variable "$name" does not exist})
        if not exists $parse->{variables}->{$name};
    return $parse->{variables}->{$name};
} ## end sub My_Nodes::variable::doit

sub My_Nodes::primary::doit {
    my ($self, $parse) = @_;
    return $self->[0];
}
sub My_Nodes::parens::doit  {
    my ($self, $parse) = @_;
    return $self->[0]->doit($parse);
}

sub My_Nodes::power::doit {
    my ($self, $parse) = @_;
    my ( $a, $b ) = @{$self};
    return $a->doit($parse)**$b->doit($parse);
}

# vim: expandtab shiftwidth=4:
