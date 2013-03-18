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
    plan tests => 3;
}

use MarpaX::Import;
ok(1);
my $any = MarpaX::Import->new();
open(GRAMMAR, '<', File::Spec->catfile($Bin, File::Spec->updir(), 'data', 'scanless.bnf')) || die "Cannot open scanless.bnf, $!\n";
my $data = do { local $/; <GRAMMAR> };
close(GRAMMAR);

my $grammar = $any->grammar($data, { default_action => 'do_arg0' });
our %BINOP_CLOSURE;
BEGIN {
    %BINOP_CLOSURE = (
        '*' => sub { $_[0] * $_[1] },
        '/' => sub {
            Marpa::R2::Context::bail('Division by zero') if not $_[1];
            $_[0] / $_[1];
        },
        '+' => sub { $_[0] + $_[1] },
        '-' => sub { $_[0] - $_[1] },
        '^' => sub { $_[0]**$_[1] },
    );
}
sub do_binop {
    my ( $op, $left, $right ) = @_;
    my $closure = $BINOP_CLOSURE{$op};
    Marpa::R2::Context::bail(
	qq{Do not know how to perform binary operation "$op"})
	if not defined $closure;
    return $closure->( $left, $right );
}

my $closures = {
    do_is_var => sub {
	my ( $self, $var ) = @_;
	$var = $var->[0];
	my $value = $self->{symbol_table}->{$var};
	Marpa::R2::Context::bail(qq{Undefined variable "$var"})
	    if not defined $value;
	return $value;
    },
    do_set_var => sub {
	my ( $self, $var, undef, $value ) = @_;
	return $self->{symbol_table}->{$var} = $value;
    },
    do_negate => sub {
	return -$_[2];
    },
    do_arg0 => sub {
	return $_[1];
    },
    do_arg1 => sub {
	return $_[2];
    },
    do_arg2 => sub {
	return $_[3];
    },
    do_array => sub {
	my ( undef, $left, undef, $right ) = @_;
	my @value = ();
	my $ref;
	if ( $ref = ref $left ) {
	    Marpa::R2::Context::bail("Bad ref type for array operand: $ref")
		if $ref ne 'ARRAY';
	    push @value, @{$left};
	}
	else {
	    push @value, $left;
	}
	if ( $ref = ref $right ) {
	    Marpa::R2::Context::bail("Bad ref type for array operand: $ref")
		if $ref ne 'ARRAY';
	    push @value, @{$right};
	}
	else {
	    push @value, $right;
	}
	return \@value;
    },
    do_binop => sub {
        return do_binop(@_);
    },
    do_caret => sub {
	my ( undef, $left, undef, $right ) = @_;
	return do_binop( '^', $left, $right );
    },
    do_star => sub {
	my ( undef, $left, undef, $right ) = @_;
	return do_binop( '*', $left, $right );
    },
    do_slash => sub {
	my ( undef, $left, undef, $right ) = @_;
	return do_binop( '/', $left, $right );
    },
    do_plus => sub {
	my ( undef, $left, undef, $right ) = @_;
	return do_binop( '+', $left, $right );
    },
    do_minus => sub {
	my ( undef, $left, undef, $right ) = @_;
	return do_binop( '-', $left, $right );
    },
    do_reduce => sub {
	my ( undef, $op, undef, $args ) = @_;
	my $closure = $BINOP_CLOSURE{$op};
	Marpa::R2::Context::bail(
	    qq{Do not know how to perform binary operation "$op"})
	    if not defined $closure;
	$args = [$args] if ref $args eq '';
	my @stack = @{$args};
      OP: while (1) {
	  return $stack[0] if scalar @stack <= 1;
	  my $result = $closure->( $stack[-2], $stack[-1] );
	  splice @stack, -2, 2, $result;
      }
	Marpa::R2::Context::bail('Should not get here');
    }
};
ok(defined($grammar));
ok(${$any->recognize($grammar, "4 * 3 + 42 / 1", $closures)}, eval "4 * 3 + 42 / 1");
