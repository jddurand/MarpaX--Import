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

# Synopsis for Stuizand interface

use 5.010;
use strict;
use warnings;
use Test::More tests => 1;
use File::Spec;
use MarpaX::Import;
use Log::Log4perl qw /:easy/;
use Log::Any::Adapter;
use FindBin qw/$Bin/;

Log::Log4perl::init(File::Spec->catfile($Bin, File::Spec->updir, 'log4perl.conf'));
Log::Any::Adapter->set('Log4perl');

## no critic (ErrorHandling::RequireCarping);

# Marpa::R2::Display
# name: Stuifzand Synopsis

my $any = MarpaX::Import->new();
my $data = do { local $/; <DATA> };
my $grammar = $any->grammar($data,
                            {
                             actions        => 'My_Actions',
                             default_action => 'do_first_arg'
                            });
# Marpa::R2::Display::End

sub My_Actions::do_parens    { shift; return $_[1] }
sub My_Actions::do_add       { shift; return $_[0] + $_[2] }
sub My_Actions::do_subtract  { shift; return $_[0] - $_[2] }
sub My_Actions::do_multiply  { shift; return $_[0] * $_[2] }
sub My_Actions::do_divide    { shift; return $_[0] / $_[2] }
sub My_Actions::do_pow       { shift; return $_[0]**$_[2] }
sub My_Actions::do_first_arg { shift; return shift; }
sub My_Actions::do_script    { shift; return join q{ }, @_ }

sub my_parser {
    my ( $grammar, $string ) = @_;
    my $value_ref = $any->recognize($grammar, $string);
    if (defined($value_ref)) {
        return ${$value_ref};
    } else {
        return 'No Parse';
    }
} ## end sub my_parser

my $value = my_parser( $grammar, '42*2+7/3, 42*(2+7)/3, 2**7-3, 2**(7-3)' );

Test::More::like( $value, qr/\A 86[.]3\d+ \s+ 126 \s+ 125 \s+ 16\z/xms, 'Value of Stuifzand parse' );

# Local Variables:
#   mode: cperl
#   cperl-indent-level: 4
#   fill-column: 100
# End:
# vim: expandtab shiftwidth=4:

__DATA__
:start ::= Script
Script ::= Expression+ separator => <op comma> action => do_script
Expression ::=
    Number
    | (<op lparen>) Expression (<op rparen>) action => do_parens assoc => group
   || Expression (<op pow>) Expression action => do_pow assoc => right
   || Expression (<op times>) Expression action => do_multiply
    | Expression (<op divide>) Expression action => do_divide
   || Expression (<op add>) Expression action => do_add
    | Expression (<op subtract>) Expression action => do_subtract

Number        ~ qr/\d+/
<op pow>      ~ qr/[\^]/
<op pow>      ~ qr/[*][*]/         /* order matters! */
<op times>    ~ qr/[*]/            // order matters!
<op divide>   ~ qr/[\/]/
<op add>      ~ qr/[+]/
<op subtract> ~ qr/[-]/
<op lparen>   ~ qr/[(]/
<op rparen>   ~ qr/[)]/
<op comma>    ::= qr/[,]/
