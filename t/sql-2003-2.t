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
    @expressions = (
	#
	## From http://www.itl.nist.gov/div897/ctg/dm/sql_examples.htm
	#
	## Need to resolve remaining ambiguities in the SQL grammar...
	#
	# 'CREATE TABLE STATION (ID INTEGER PRIMARY KEY, CITY CHAR(20), STATE CHAR(2), LAT_N REAL, LONG_W REAL);'
	);
    plan tests => 1 + scalar(@expressions);
}

use MarpaX::Import;
ok(1);

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

my $any = MarpaX::Import->new();

open(GRAMMAR, '<', File::Spec->catfile($Bin, File::Spec->updir(), 'data', 'sql-2003-2.ebnf')) || die "Cannot open sql-2003-2.ebnf, $!\n";
my $data = do { local $/; <GRAMMAR> };
close(GRAMMAR);
#
## MODIFICATIONS TO THE ORIGINAL as per http://savage.net.au/SQL/sql-2003-2.bnf
## ----------------------------------------------------------------------------
##  1. REMOVAL: very first lines has been skipped (BNF Grammar for ... up to the first --p)
##  2. CHANGE : <space> ::= ' '
##  3. CHANGE : from to <double quote> to <right brace>: quoted definitions
##  4. CHANGE : <identifier_start> ::= /[[:alpha:]_]/
##  5. CHANGE : <identifier_extend> ::= /[[:digit:]]/
##  6. CHANGE : <Unicode_escape_character> ::= "\u"
##  7. CHANGE : <nondoublequote_character> ::= [^"]
##  8. CHANGE : <newline> ::= /\r*\n/
##  9. CHANGE : <nonquote_character> ::= [^']
## 10. REMOVAL: <preparable implementation-defined statement>
## 11. REMOVAL: <direct implementation-defined statement>
## 12. CHANGE : <SQLSTATE class value> ::= <SQLSTATE char><SQLSTATE char>
## 13. CHANGE : <SQLSTATE subclass value> ::= <SQLSTATE char><SQLSTATE char><SQLSTATE char>
## 14. CHANGE : <XXX host identifier> ::= /[[:alpha:]][[:alnum:]]*/
## 15. CHANGE : <embedded SQL XXX program> ::= EXEC XXX_SQL
## 16. CHANGE : <host PL/I label variable> ::= /[[:alpha:]][[:alnum:]]*/
## 17. CHANGE : In <Fortran type specification> changed = to '='
## 18. CHANGE : In <Ada qualified type specification> changed Interfaces.SQL to 'Interfaces.SQL'
## 19. CHANGE : In <reserved word> changed END-EXEC to 'END-EXEC'
## 20. REMOVAL: Duplicate rule <item number> ::= <simple value specification>
## 21. REMOVAL: Duplicate rule <path-resolved user-defined type name> ::= <user-defined type name>
##
## As in postgresSQL, in order to define <non-escaped_character>:
## 22. ADD    : <escape_char> ::= /\\/
## 23. ADD    : <special_character>      ::=  /\[\]\(\)\|\^\-\+\*%_\?\{/
## 24. ADD    : <escaped_character>      ::=  <escape-char> <special_character> | <escape-char> <escape-char>
## 25. ADD    : <non-escaped_character> ::= /./ - ( <special_character> | <escape-char> )
##
## 26. REMOVAL: Removed uncommented line: Table 16 -- Data type correspondences for C
## 27. CHANGE : added missing --/h2 after --h2 19 Dynamic SQL
## 28. CHANGE : added missing --/h2 after --h2 22 Diagnostics management
## 29. ADD    : <unsigned integer> is missing: <unsigned integer> ::= /[0-9]+/
## 30. ADD    : <unqualified schema name> is missing:  <unqualified schema name> ::= <identifier>
##
## Marpa does not like then few things:
##
## Nullable symbol "user-defined type option" is on rhs of counted rule
## Indeed, <user-defined type option> ::= <instantiable clause> || <finality> || <reference type specification> || <ref cast option> || <cast option>
## and wee that: <ref cast option> ::= [ <cast to ref> ] [ <cast to type> ]              (nullable)
##               <cast option> ::= [ <cast to distinct> ] [ <cast to source> ]           (nullable)
## 29. CHANGE : <ref cast option> ::= <cast to ref> <cast to type> | <cast to ref> | <cast to type>
## 30. CHANGE : <cast option> ::= <cast to distinct> <cast to source> | <cast to distinct> | <cast to source>
## 31. REMOVAL: <direct implementation-defined statement>
## 32. REMOVAL: <preparable implementation-defined statement>
## 33. CHANGE : , by <comma> in <character set specification list>
## 34. CHANGE : , by <comma> in <SQL condition>
##
## This grammar has a lot of possible parse trees. Mostly because of the identifier definition:
## <regular identifier> ::= <identifier body>
## <identifier body> ::= <identifier start> [ <identifier part>... ]
## <identifier part> ::= <identifier start> | <identifier extend>
## <identifier start> ::= /[[:alpha:]_]/
## <identifier extend> ::= /[[:digit:]]/
## These has all been replaced by:
## <regular identifier> ::= /[[:alpha:]_]+[[:alpha:][:digit:]]*/
## Even with that grouping, parse trees is usually not zero.
##
## This grammar is leaving few lhs up to the implementation to add support to it. For instance 'token' and 'regular expression'.
## But not too much -;
#
my @startrules = ('SQL-client module definition',
                  'embedded SQL declare section',
                  'embedded SQL statement',
                  'embedded SQL host program',
                  'preparable statement',
                  'direct SQL statement',);
$any->startrules([@startrules]);
# $any->debug(1);
my $hashp = $any->grammar($data);
my $closures = {};
foreach (@expressions) {
    # use Data::Dumper;
    # print STDERR Dumper($_);
    # $any->trace_values(1);
    # $any->trace_actions(1);
    ok($any->recognize($hashp, $_, $closures), eval $_);
}
