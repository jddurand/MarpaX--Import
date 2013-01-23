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

open(GRAMMAR, '<', File::Spec->catfile($Bin, File::Spec->updir(), 'data', 'calculator.ebnf')) || die "Cannot open calculator.ebnf, $!\n";
my $data = do { local $/; <GRAMMAR> };
close(GRAMMAR);
my $grammar = $any->grammar($data, { startrules => [qw/expression/], default_action => 'do_push' });
my $closures = {
    do_push => sub {
	shift;
	$any->dumparg('==> do_push', @_);
	my $rc = [ @_ ];
	$any->dumparg('<== do_push', $rc);
	return $rc;
    },
    do_group => sub {
	shift;
	$any->dumparg('==> do_group', @_);
	my $rc = $_[1];
	$any->dumparg('<== do_group', $rc);
	return $rc;
    },
    do_factor => sub {
	shift;
	$any->dumparg('==> do_factor', @_);
	my $rc = $_[0];
	$any->dumparg('<== do_factor', $rc);
	return $rc+0;
    },
    do_pow => sub {
	shift;
	$any->dumparg('==> do_pow', @_);
	my ($rc, $remaining) = @_;
	foreach (@{$remaining}) {
	    $rc **= $_->[1];
	}
	$any->dumparg('<== do_pow', $rc);
	return $rc;
    },
    do_term => sub {
	shift;
	$any->dumparg('==> do_term', @_);
	my ($rc, $remaining) = @_;
	foreach (@{$remaining}) {
	    if ($_->[0] eq '*') {
		$rc *= $_->[1];
	    } else {
		$rc /= $_->[1];
	    }
	}
	$any->dumparg('<== do_term', $rc);
	return $rc;
    },
    do_expression => sub {
	shift;
	$any->dumparg('==> do_expression', @_);
	my ($rc, $remaining) = @_;
	foreach (@{$remaining}) {
	    if ($_->[0] eq '+') {
		$rc += $_->[1];
	    } else {
		$rc -= $_->[1];
	    }
	}
	$any->dumparg('<== do_expression', $rc);
	return $rc;
    },
};
foreach (@expressions) {
    ok(${$any->recognize($grammar, $_, $closures)}, eval $_);
}
