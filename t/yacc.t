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

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

my $any = MarpaX::Import->new();

open(GRAMMAR, '<', File::Spec->catfile($Bin, File::Spec->updir(), 'data', 'yacc.ebnf')) || die "Cannot open yacc.ebnf, $!\n";
my $data = do { local $/; <GRAMMAR> };
close(GRAMMAR);
ok(defined($any->grammar($data)));
