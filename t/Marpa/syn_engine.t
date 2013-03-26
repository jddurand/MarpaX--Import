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

# Engine Synopsis

use 5.010;
use strict;
use warnings;
use Test::More tests => 2;
use File::Spec;
use MarpaX::Import;
use Log::Log4perl qw /:easy/;
use Log::Any::Adapter;
use FindBin qw/$Bin/;

Log::Log4perl::init(File::Spec->catfile($Bin, File::Spec->updir, 'log4perl.conf'));
Log::Any::Adapter->set('Log4perl');

## no critic (ErrorHandling::RequireCarping);

# Marpa::R2::Display
# name: Engine Synopsis Unambiguous Parse

my $any = MarpaX::Import->new();
my $unambiguous_grammar = $any->grammar('
Expression ::= Term
Term       ::= Factor
Factor     ::= Number
Term       ::= Term Add Term          action => do_add
Factor     ::= Factor Multiply Factor action => do_multiply

Number   ~ [\d]+
Add      ~ "+"
Multiply ~ "*"
'
                            ,
                            {
                             actions        => 'My_Actions',
                             default_action => 'first_arg',
                             marpa_compat   => 1,
                             startrules     => [qw/Expression/]
                            });
my $input = '42 * 1 + 7';

sub My_Actions::do_add {
    my ( undef, $t1, undef, $t2 ) = @_;
    return $t1 + $t2;
}

sub My_Actions::do_multiply {
    my ( undef, $t1, undef, $t2 ) = @_;
    return $t1 * $t2;
}

sub My_Actions::first_arg { shift; return shift; }

my $value_ref = $any->recognize($unambiguous_grammar, $input) || '';
my $value = $value_ref ? ${$value_ref} : 'No Parse';

# Marpa::R2::Display::End

# Ambiguous, Array Form Rules

# Marpa::R2::Display
# name: Engine Synopsis Ambiguous Parse

my $ambiguous_grammar = $any->grammar('
E ::= E Add E      action => do_add
E ::= E Multiply E action => do_multiply
E ::= Number

Number   ~ [\d]+
Add      ~ "+"
Multiply ~ "*"
'
                            ,
                            {
                             actions        => 'My_Actions',
                             default_action => 'first_arg',
                             startrules     => [qw/E/]
                            });

my @values_ref = $any->recognize($ambiguous_grammar, $input, {}, { multiple_parse_values => 1 });
my @values = map {$$_} @values_ref;

# Marpa::R2::Display::End

Test::More::is( $value, 49, 'Unambiguous Value' );
Test::More::is_deeply( [ sort @values ], [ 336, 49 ], 'Ambiguous Values' );

1;    # In case used as "do" file

# Local Variables:
#   mode: cperl
#   cperl-indent-level: 4
#   fill-column: 100
# End:
# vim: expandtab shiftwidth=4:

__DATA__
