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

our @xmls;

BEGIN {
    #
    ## From http://www.w3.org/TR/REC-xml
    #
    @xmls = (
	[ 'note.xml', 'ISO-8859-1' ],
	[ 'cd_catalog.xml', 'ISO-8859-1' ],
	);
    plan tests => 1 + 2 * scalar(@xmls);
}

use MarpaX::Import;
ok(1);

#########################

## TAKE CARE XML grammar IS ambiguous.
## For example the Misc section can match both in prolog and in comment. When there is more than one S grammar is ambiguous as well.
## Up to you to resolve it.
## Look to http://lists.w3.org/Archives/Public/xml-editor/2011OctDec/0002.html about S.
## Hand-shake your brain for Misc.

my $any = MarpaX::Import->new();

open(GRAMMAR, '<', File::Spec->catfile($Bin, File::Spec->updir(), 'data', 'xml-1.0-5th-edition.ebnf')) || die "Cannot open xml-1.0-5th-edition.ebnf, $!\n";
my $data = do { local $/; <GRAMMAR> };
close(GRAMMAR);

$any->startrules([qw/document/]);
$any->space_re(qr//);                     # VERY important because XML Grammar handles totally the notion of "space"
$any->infinite_action('warn');            # VERY important because XML Grammar has an explicit cycle in Conditional Section
$any->auto_rank(1);                       # This reduces the number of parse tree values
my $grammar = $any->grammar($data);
my %EncName = ();
my $closures = {
    do_EncName   => sub {
	shift;
	my $EncName = shift; 
	map {$EncName .= $_->[0]} @{$_[0]} if (@_);
	$EncName{$EncName}++;
	return $EncName
    },

};
foreach (@xmls) {
    my ($file, $enc) = @{$_};
    open(XML, '<', File::Spec->catfile($Bin, File::Spec->updir(), 'data', $file)) || die "Cannot open $file, $!\n";
    my $xml = do { local $/; <XML> };
    close(XML);
    $any->multiple_parse_values(1);
    $any->recognize($grammar, $xml, $closures);
    ok(keys %EncName, 1);
    ok((keys %EncName)[0], $enc);
}
