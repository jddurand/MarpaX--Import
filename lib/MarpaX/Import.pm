# *****************************************************************************
#
package MarpaX::Import;
#
# *****************************************************************************

use strict;
use warnings;
use Marpa::R2;
use Regexp::Common 'RE_ALL';
use IO::Handle;
use locale;
use feature 'unicode_strings';
use MarpaX::Import::Grammar;
use File::Temp;
use MarpaX::Import::MarpaLogger;
use Log::Any qw/$log/;
use Data::Dumper;

autoflush STDOUT 1;
#
## Support of Marpa's BNF, W3C's EBNF, Marpa's BNF+scanless
##
## This module started after reading "Sample CSS Parser using Marpa::XS"
## at https://gist.github.com/1511584
##
## General rule:
## All generated rules use an internal action. The return value from all internal
## actions is always a reference to an array
## All user's actions are handled explicitely by an action proxy that
## dereferences the return values to internal actions.
## All user's actions return value are stored as a reference to them.
##
## When we just want to propagate the array reference from one rule to another
## we just use ::first
#
require Exporter;
use AutoLoader qw(AUTOLOAD);
use Carp;

#
## Debug of proxy actions can be performed only by setting this variable
#
our $DEBUG_PROXY_ACTIONS = 0;
our @ISA = qw(Exporter);
our %EXPORT_TAGS = ( 'all' => [ qw// ] );
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = qw//;

use constant {
    BEGSTRINGPOSMINUSONE   => $[ - 1,
    TOKEN_TYPE_REGEXP      => 0,
    TOKEN_TYPE_STRING      => 1,
};
our $VERSION = '0.01';

our $INTERNAL_MARKER = sprintf('%s::',__PACKAGE__);
our $ACTION_LAST_ARG = sprintf('%s%s', $INTERNAL_MARKER, 'action_last_arg');
our $ACTION_ODD_ARGS = sprintf('%s%s', $INTERNAL_MARKER, 'action_odd_args');
our $ACTION_SECOND_ARG = sprintf('%s%s', $INTERNAL_MARKER, 'action_second_arg');
our $ACTION_MAKE_ARRAYP = sprintf('%s%s', $INTERNAL_MARKER, 'action_make_arrayp');
our $ACTION_ARGS = sprintf('%s%s', $INTERNAL_MARKER, 'action_args');
our $ACTION_FIRST_ARG = '::first'; # sprintf('%s%s', $INTERNAL_MARKER, 'action_first_arg');
our $ACTION_WHATEVER = '::whatever';
our $ACTION_TWO_ARGS_RECURSIVE = sprintf('%s%s', $INTERNAL_MARKER, 'action_two_args_recursive');
our $MARPA_TRACE_FILE_HANDLE;
our $MARPA_TRACE_BUFFER;

sub BEGIN {    
    #
    ## We do not want Marpa to pollute STDERR
    #
    ## Autovivify a new file handle
    #
    open($MARPA_TRACE_FILE_HANDLE, '>', \$MARPA_TRACE_BUFFER);
    if (! defined($MARPA_TRACE_FILE_HANDLE)) {
      carp "Cannot create temporary file handle to tie Marpa logging, $!\n";
    } else {
      if (! tie ${$MARPA_TRACE_FILE_HANDLE}, 'MarpaX::Import::MarpaLogger') {
        carp "Cannot tie $MARPA_TRACE_FILE_HANDLE, $!\n";
        if (! close($MARPA_TRACE_FILE_HANDLE)) {
          carp "Cannot close temporary file handle, $!\n";
        }
        $MARPA_TRACE_FILE_HANDLE = undef;
      }
    }
}
our %TOKENS = ();
$TOKENS{DIGITS} = __PACKAGE__->make_token('', undef, qr/\G(?:[[:digit:]]+)/ms, undef, undef, undef);
$TOKENS{COMMA} = __PACKAGE__->make_token('', undef, ',', undef, undef, undef);
$TOKENS{HINT_OP} = __PACKAGE__->make_token('', undef, '=>', undef, undef, undef);
$TOKENS{REDIRECT} = __PACKAGE__->make_token('', undef, '>', undef, undef, undef);
$TOKENS{G1_RULESEP_01} = __PACKAGE__->make_token('', undef, '::=', undef, undef);
$TOKENS{G1_RULESEP_02} = __PACKAGE__->make_token('', undef, ':', undef, undef);
$TOKENS{G1_RULESEP_03} = __PACKAGE__->make_token('', undef, '=', undef, undef);
$TOKENS{G0_RULESEP} = __PACKAGE__->make_token('', undef, '~', undef, undef, undef);
$TOKENS{PIPE_01} = __PACKAGE__->make_token('', undef, '|', undef, undef, undef);
$TOKENS{PIPE_02} = __PACKAGE__->make_token('', undef, '||', undef, undef, undef);
$TOKENS{MINUS} = __PACKAGE__->make_token('', undef, '-', undef, undef, undef);
$TOKENS{STAR} = __PACKAGE__->make_token('', undef, '*', undef, undef, undef);
$TOKENS{PLUS_01} = __PACKAGE__->make_token('', undef, '+', undef, undef, undef);
$TOKENS{PLUS_02} = __PACKAGE__->make_token('', undef, '...', undef, undef, undef);
$TOKENS{RULEEND_01} = __PACKAGE__->make_token('', undef, ';', undef, undef, undef);
$TOKENS{RULEEND_02} = __PACKAGE__->make_token('', undef, '.', undef, undef, undef);
$TOKENS{QUESTIONMARK} = __PACKAGE__->make_token('', undef, '?', undef, undef, undef);
#
## We do not follow Marpa convention saying that \ is NOT an escaped character
#
$TOKENS{STRING} = __PACKAGE__->make_token('', undef, qr/\G(?:$RE{delimited}{-delim=>q{'"}})/ms, undef, undef, undef);
$TOKENS{WORD} = __PACKAGE__->make_token('', undef, qr/\G(?:[[:word:]]+)/ms, undef, undef, undef);
$TOKENS{SYMBOL__START} = __PACKAGE__->make_token('', undef, ':start', undef, undef, undef);
$TOKENS{SYMBOL__DISCARD} = __PACKAGE__->make_token('', undef, ':discard', undef, undef, undef);
$TOKENS{LBRACKET} = __PACKAGE__->make_token('', undef, '[', undef, undef);
$TOKENS{RBRACKET} = __PACKAGE__->make_token('', undef, ']', undef, undef, undef);
$TOKENS{LPAREN} = __PACKAGE__->make_token('', undef, '(', undef, undef, undef);
$TOKENS{RPAREN} = __PACKAGE__->make_token('', undef, ')', undef, undef, undef);
$TOKENS{LCURLY} = __PACKAGE__->make_token('', undef, '{', undef, undef, undef);
$TOKENS{RCURLY} = __PACKAGE__->make_token('', undef, '}', undef, undef, undef);
$TOKENS{SYMBOL_BALANCED} = __PACKAGE__->make_token('', undef, qr/\G$RE{balanced}{-parens=>'<>'}/ms, undef, undef, undef);
$TOKENS{HEXCHAR} = __PACKAGE__->make_token('', undef, qr/\G(#x([[:xdigit:]]+))/ms, undef, undef, undef);
$TOKENS{CHAR_RANGE} = __PACKAGE__->make_token('', undef, qr/\G(\[(#x[[:xdigit:]]+|[^\^][^[:cntrl:][:space:]]*?)(?:\-(#x[[:xdigit:]]+|[^[:cntrl:][:space:]]+?))?\])/ms, undef, undef, undef);
$TOKENS{CARET_CHAR_RANGE} = __PACKAGE__->make_token('', undef, qr/\G(\[\^(#x[[:xdigit:]]+|[^[:cntrl:][:space:]]+?)(?:\-(#x[[:xdigit:]]+|[^[:cntrl:][:space:]]+?))?\])/ms,  undef, undef, undef);
$TOKENS{RANK} = __PACKAGE__->make_token('', undef, 'rank', undef, undef, undef);
$TOKENS{RANK_VALUE} = __PACKAGE__->make_token('', undef, qr/\G(?:\-?[[:digit:]]+)/ms, undef, undef, undef);
$TOKENS{ACTION} = __PACKAGE__->make_token('', undef, 'action', undef, undef, undef);
$TOKENS{ACTION_VALUE} = __PACKAGE__->make_token('', undef, qr/\G(?:::first|::array|::dwim|::undef|::whatever|[[:alpha:]][[:word:]]*|$RE{balanced}{-parens=>'{}'})/ms, undef, undef, undef);
$TOKENS{BLESS} = __PACKAGE__->make_token('', undef, 'bless', undef, undef, undef);
$TOKENS{BLESS_VALUE} = __PACKAGE__->make_token('', undef, qr/\G(?:[[:word:]]+)/ms, undef, undef, undef);
$TOKENS{PRE} = __PACKAGE__->make_token('', undef, 'pre', undef, undef, undef);
$TOKENS{PRE_VALUE} = __PACKAGE__->make_token('', undef, qr/\G(?:[[:word:]]+)/ms, undef, undef, undef);
$TOKENS{POST} = __PACKAGE__->make_token('', undef, 'post', undef, undef, undef);
$TOKENS{POST_VALUE} = __PACKAGE__->make_token('', undef, qr/\G(?:[[:word:]]+)/ms, undef, undef, undef);
$TOKENS{SEPARATOR} = __PACKAGE__->make_token('', undef, 'separator', undef, undef, undef);
$TOKENS{PROPER} = __PACKAGE__->make_token('', undef, 'proper', undef, undef, undef);
$TOKENS{PROPER_VALUE_01} = __PACKAGE__->make_token('', undef, '0', undef, undef, undef);
$TOKENS{PROPER_VALUE_02} = __PACKAGE__->make_token('', undef, '1', undef, undef, undef);
$TOKENS{ASSOC} = __PACKAGE__->make_token('', undef, 'assoc', undef, undef, undef);
$TOKENS{ASSOC_VALUE_01} = __PACKAGE__->make_token('', undef, 'left', undef, undef, undef);
$TOKENS{ASSOC_VALUE_02} = __PACKAGE__->make_token('', undef, 'group', undef, undef, undef);
$TOKENS{ASSOC_VALUE_03} = __PACKAGE__->make_token('', undef, 'right', undef, undef, undef);
$TOKENS{RULENUMBER} = __PACKAGE__->make_token('', undef, qr/\G(?:\[[[:digit:]][^\]]*\])/ms, undef, undef, undef);
$TOKENS{REGEXP} = __PACKAGE__->make_token('', undef, qr/\G(?:qr$RE{delimited}{-delim=>q{\/}})/ms, undef, undef, undef);
$TOKENS{SPACE_01} = __PACKAGE__->make_token('', undef, "\f", undef, undef, undef);
$TOKENS{SPACE_02} = __PACKAGE__->make_token('', undef, "\r", undef, undef, undef);
$TOKENS{SPACE_03} = __PACKAGE__->make_token('', undef, "\t", undef, undef, undef);
$TOKENS{SPACE_04} = __PACKAGE__->make_token('', undef, ' ', undef, undef, undef);
$TOKENS{NEWLINE} = __PACKAGE__->make_token('', undef, "\n", undef, undef, undef);
$TOKENS{NEWRULENUMBER} = __PACKAGE__->make_token('', undef, qr/\G(?:\n[\f\r\t ]*\n[\f\r\t ]*\[[[:digit:]][^\]]*\])/ms, undef, undef, undef);
$TOKENS{W3CIGNORE} = __PACKAGE__->make_token('', undef, qr/\G(?:$RE{balanced}{-begin => '[wfc|[WFC|[vc|[VC'}{-end => ']|]|]|]'})/ms, undef, undef, undef);
$TOKENS{COMMENT_CPP} = __PACKAGE__->make_token('', undef, qr/\G(?:$RE{comment}{'C++'})/ms, undef, undef, undef);
#$TOKENS{COMMENT_PERL} = __PACKAGE__->make_token('', undef, qr/\G(?:^[\f\r\t ]*$RE{comment}{Perl})/ms, undef, undef, undef);
$TOKENS{COMMENT_PERL} = __PACKAGE__->make_token('', undef, qr/\G(?:$RE{comment}{Perl})/ms, undef,
						#
						## Pre-code for COMMENT_PERL : is has have nothing before in the same line
						# $self = $_[0]
						# $string = $_[1]
						# $line = $_[2]
						# $tokensp = $_[3]
						# $pos = $_[4]
						# $posline = $_[5]
						# $linenb = $_[6]
						# $expected = $_[7]
						# $matchesp = $_[8]
						# $longest_match = $_[9]
						# $token_name = $_[10]
						#
						sub {return ($_[2] =~ /^[\f\r\t ]*\G/o) },
						undef);
$TOKENS{WEBCODE} = __PACKAGE__->make_token('', undef, qr/\G(?:\-\-(?:hr|##)[^\n]*\n|$RE{balanced}{-begin => '--p|--i|--h2|--h3|--bl|--small'}{-end => '--\/p|--\/i|--\/h2|--\/h3|--\/bl|--\/small'})/ms, undef, undef, undef);

our $GRAMMAR = Marpa::R2::Grammar->new
    (
     {
	 start                => ':start',
	 terminals            => [keys %TOKENS],
	 actions              => __PACKAGE__,
	 trace_file_handle    => $MARPA_TRACE_FILE_HANDLE,
	 rules                =>
	     [
              #
              ## discard section
              #
	      { lhs => ':discard',                rhs => [qw/NEWRULENUMBER/], rank => 1,        action => $ACTION_WHATEVER },
	      { lhs => ':discard',                rhs => [qw/NEWLINE/],                         action => $ACTION_WHATEVER },
	      { lhs => ':discard',                rhs => [qw/SPACE_01/],                        action => $ACTION_WHATEVER },
	      { lhs => ':discard',                rhs => [qw/SPACE_02/],                        action => $ACTION_WHATEVER },
	      { lhs => ':discard',                rhs => [qw/SPACE_03/],                        action => $ACTION_WHATEVER },
	      { lhs => ':discard',                rhs => [qw/SPACE_04/],                        action => $ACTION_WHATEVER },
	      { lhs => ':discard',                rhs => [qw/W3CIGNORE/],                       action => $ACTION_WHATEVER },
	      { lhs => ':discard',                rhs => [qw/COMMENT_CPP/],                     action => $ACTION_WHATEVER },
	      { lhs => ':discard',                rhs => [qw/COMMENT_PERL/],                    action => $ACTION_WHATEVER },
	      { lhs => ':discard',                rhs => [qw/WEBCODE/],                         action => $ACTION_WHATEVER },
	      { lhs => ':discard_any',            rhs => [qw/:discard/], min => 0,              action => $ACTION_WHATEVER },
              #
              ## Tokens section
              #
	      { lhs => ':DIGITS',                 rhs => [qw/DIGITS :discard_any/],             action => $ACTION_FIRST_ARG },
	      { lhs => ':COMMA',                  rhs => [qw/COMMA :discard_any/],              action => $ACTION_FIRST_ARG },
	      { lhs => ':HINT_OP',                rhs => [qw/HINT_OP :discard_any/],            action => $ACTION_FIRST_ARG },
	      { lhs => ':REDIRECT',               rhs => [qw/REDIRECT :discard_any/],           action => $ACTION_FIRST_ARG },
	      { lhs => ':G1_RULESEP_01',          rhs => [qw/G1_RULESEP_01 :discard_any/],      action => $ACTION_FIRST_ARG },
	      { lhs => ':G1_RULESEP_02',          rhs => [qw/G1_RULESEP_02 :discard_any/],      action => $ACTION_FIRST_ARG },
	      { lhs => ':G1_RULESEP_03',          rhs => [qw/G1_RULESEP_03 :discard_any/],      action => $ACTION_FIRST_ARG },
	      { lhs => ':G1_RULESEP',             rhs => [qw/:G1_RULESEP_01/],                  action => $ACTION_FIRST_ARG },
	      { lhs => ':G1_RULESEP',             rhs => [qw/:G1_RULESEP_02/],                  action => $ACTION_FIRST_ARG },
	      { lhs => ':G1_RULESEP',             rhs => [qw/:G1_RULESEP_03/],                  action => $ACTION_FIRST_ARG },
	      #
	      ## Ambiguities in our grammar: => must be interpreted by starting with '='
	      #
	      { lhs => ':G0_RULESEP',             rhs => [qw/G0_RULESEP :discard_any/],         action => $ACTION_FIRST_ARG },
	      { lhs => ':PIPE_01',                rhs => [qw/PIPE_01 :discard_any/],            action => $ACTION_FIRST_ARG },
	      { lhs => ':PIPE_02',                rhs => [qw/PIPE_02 :discard_any/],            action => $ACTION_FIRST_ARG },
	      { lhs => ':PIPE',                   rhs => [qw/:PIPE_01/],                        action => $ACTION_FIRST_ARG },
	      { lhs => ':PIPE',                   rhs => [qw/:PIPE_02/],                        action => $ACTION_FIRST_ARG },
	      { lhs => ':MINUS',                  rhs => [qw/MINUS :discard_any/],              action => $ACTION_FIRST_ARG },
	      { lhs => ':STAR',                   rhs => [qw/STAR :discard_any/],               action => $ACTION_FIRST_ARG },
	      { lhs => ':PLUS_01',                rhs => [qw/PLUS_01 :discard_any/],            action => $ACTION_FIRST_ARG },
	      { lhs => ':PLUS_02',                rhs => [qw/PLUS_02 :discard_any/],            action => $ACTION_FIRST_ARG },
	      { lhs => ':PLUS',                   rhs => [qw/:PLUS_01/],                        action => $ACTION_FIRST_ARG },
	      { lhs => ':PLUS',                   rhs => [qw/:PLUS_02/],                        action => $ACTION_FIRST_ARG },
	      { lhs => ':RULEEND_01',             rhs => [qw/RULEEND_01 :discard_any/],         action => $ACTION_FIRST_ARG },
	      { lhs => ':RULEEND_02',             rhs => [qw/RULEEND_02 :discard_any/],         action => $ACTION_FIRST_ARG },
	      { lhs => ':RULEEND',                rhs => [qw/:RULEEND_01/],                     action => $ACTION_FIRST_ARG },
	      { lhs => ':RULEEND',                rhs => [qw/:RULEEND_02/],                     action => $ACTION_FIRST_ARG },
	      { lhs => ':QUESTIONMARK',           rhs => [qw/QUESTIONMARK :discard_any/],       action => $ACTION_FIRST_ARG },
	      { lhs => ':STRING',                 rhs => [qw/STRING :discard_any/],             action => $ACTION_FIRST_ARG },
	      { lhs => ':WORD',                   rhs => [qw/WORD :discard_any/],               action => $ACTION_FIRST_ARG },
	      { lhs => ':SYMBOL__START',          rhs => [qw/SYMBOL__START :discard_any/],      action => $ACTION_FIRST_ARG },
	      { lhs => ':SYMBOL__DISCARD',        rhs => [qw/SYMBOL__DISCARD :discard_any/],    action => $ACTION_FIRST_ARG },
	      { lhs => ':LBRACKET',               rhs => [qw/LBRACKET :discard_any/],           action => $ACTION_FIRST_ARG },
	      { lhs => ':RBRACKET',               rhs => [qw/RBRACKET :discard_any/],           action => $ACTION_FIRST_ARG },
	      { lhs => ':LPAREN',                 rhs => [qw/LPAREN :discard_any/],             action => $ACTION_FIRST_ARG },
	      { lhs => ':RPAREN',                 rhs => [qw/RPAREN :discard_any/],             action => $ACTION_FIRST_ARG },
	      { lhs => ':LCURLY',                 rhs => [qw/LCURLY :discard_any/],             action => $ACTION_FIRST_ARG },
	      { lhs => ':RCURLY',                 rhs => [qw/RCURLY :discard_any/],             action => $ACTION_FIRST_ARG },
	      { lhs => ':SYMBOL_BALANCED',        rhs => [qw/SYMBOL_BALANCED :discard_any/],    action => $ACTION_FIRST_ARG },
	      { lhs => ':HEXCHAR',                rhs => [qw/HEXCHAR :discard_any/],            action => $ACTION_FIRST_ARG },
	      { lhs => ':CHAR_RANGE',             rhs => [qw/CHAR_RANGE :discard_any/],         action => $ACTION_FIRST_ARG },
	      { lhs => ':CARET_CHAR_RANGE',       rhs => [qw/CARET_CHAR_RANGE :discard_any/],   action => $ACTION_FIRST_ARG },
	      { lhs => ':RANK',                   rhs => [qw/RANK :discard_any/],               action => $ACTION_FIRST_ARG },
	      { lhs => ':RANK_VALUE',             rhs => [qw/RANK_VALUE :discard_any/],         action => $ACTION_FIRST_ARG },
	      { lhs => ':ACTION',                 rhs => [qw/ACTION :discard_any/],             action => $ACTION_FIRST_ARG },
	      { lhs => ':ACTION_VALUE',           rhs => [qw/ACTION_VALUE :discard_any/],       action => $ACTION_FIRST_ARG },
	      { lhs => ':BLESS',                  rhs => [qw/BLESS :discard_any/],              action => $ACTION_FIRST_ARG },
	      { lhs => ':BLESS_VALUE',            rhs => [qw/BLESS_VALUE :discard_any/],        action => $ACTION_FIRST_ARG },
	      { lhs => ':PRE',                    rhs => [qw/PRE :discard_any/],                action => $ACTION_FIRST_ARG },
	      { lhs => ':PRE_VALUE',              rhs => [qw/PRE_VALUE :discard_any/],          action => $ACTION_FIRST_ARG },
	      { lhs => ':POST',                   rhs => [qw/POST :discard_any/],               action => $ACTION_FIRST_ARG },
	      { lhs => ':POST_VALUE',             rhs => [qw/POST_VALUE :discard_any/],         action => $ACTION_FIRST_ARG },
	      { lhs => ':SEPARATOR',              rhs => [qw/SEPARATOR :discard_any/],          action => $ACTION_FIRST_ARG },
	      { lhs => ':PROPER',                 rhs => [qw/PROPER :discard_any/],             action => $ACTION_FIRST_ARG },
	      { lhs => ':PROPER_VALUE_01',        rhs => [qw/PROPER_VALUE_01 :discard_any/],    action => $ACTION_FIRST_ARG },
	      { lhs => ':PROPER_VALUE_02',        rhs => [qw/PROPER_VALUE_02 :discard_any/],    action => $ACTION_FIRST_ARG },
	      { lhs => ':PROPER_VALUE',           rhs => [qw/:PROPER_VALUE_01/],                action => $ACTION_FIRST_ARG },
	      { lhs => ':PROPER_VALUE',           rhs => [qw/:PROPER_VALUE_02/],                action => $ACTION_FIRST_ARG },
	      { lhs => ':ASSOC',                  rhs => [qw/ASSOC :discard_any/],              action => $ACTION_FIRST_ARG },
	      { lhs => ':ASSOC_VALUE_01',         rhs => [qw/ASSOC_VALUE_01 :discard_any/],     action => $ACTION_FIRST_ARG },
	      { lhs => ':ASSOC_VALUE_02',         rhs => [qw/ASSOC_VALUE_02 :discard_any/],     action => $ACTION_FIRST_ARG },
	      { lhs => ':ASSOC_VALUE_03',         rhs => [qw/ASSOC_VALUE_03 :discard_any/],     action => $ACTION_FIRST_ARG },
	      { lhs => ':ASSOC_VALUE',            rhs => [qw/:ASSOC_VALUE_01/],                 action => $ACTION_FIRST_ARG },
	      { lhs => ':ASSOC_VALUE',            rhs => [qw/:ASSOC_VALUE_02/],                 action => $ACTION_FIRST_ARG },
	      { lhs => ':ASSOC_VALUE',            rhs => [qw/:ASSOC_VALUE_03/],                 action => $ACTION_FIRST_ARG },
	      { lhs => ':RULENUMBER',             rhs => [qw/RULENUMBER :discard_any/],         action => $ACTION_FIRST_ARG },
	      { lhs => ':REGEXP',                 rhs => [qw/REGEXP :discard_any/],             action => $ACTION_FIRST_ARG },

	      #
              ## Rules section
              #
	      { lhs => ':start',                  rhs => [qw/:discard_any :realstart/],         action => $ACTION_SECOND_ARG },
	      { lhs => ':realstart',              rhs => [qw/rule/],  min => 1,                 action => '_action__realstart' },

	      { lhs => 'symbol_balanced',         rhs => [qw/:SYMBOL_BALANCED/],                action => '_action_symbol_balanced' },
	      { lhs => 'word',                    rhs => [qw/:WORD/],                           action => '_action_word' },

	      { lhs => 'symbol',                  rhs => [qw/symbol_balanced/],                 action => '_action_symbol' },
	      { lhs => 'symbol',                  rhs => [qw/word/],                            action => '_action_symbol' },
	      
              { lhs => 'ruleend_maybe',           rhs => [qw/:RULEEND/],                        action => '_action_ruleend_maybe' },
              { lhs => 'ruleend_maybe',           rhs => [qw//],                                action => '_action_ruleend_maybe' },

	      #
	      ## It is important to note that :discard can be ONLY writen as:
	      ## :discard RULESEP symbol
	      ## The :start rule does not have this limitation
	      #
	      { lhs => 'rule',                    rhs => [qw/             symbol          lexhints_maybe :G0_RULESEP expression ruleend_maybe/], rank => 1, action => '_action_rule' },
	      { lhs => 'rule',                    rhs => [qw/             symbol          lexhints_maybe :G1_RULESEP expression ruleend_maybe/], rank => 1, action => '_action_rule' },
	      { lhs => 'rule',                    rhs => [qw/            :SYMBOL__START   lexhints_maybe :G1_RULESEP expression ruleend_maybe/], rank => 1, action => '_action_rule' },
	      { lhs => 'rule',                    rhs => [qw/            :SYMBOL__DISCARD lexhints_maybe :G0_RULESEP symbol     ruleend_maybe/], rank => 1, action => '_action_rule' },
	      { lhs => 'rule',                    rhs => [qw/:RULENUMBER  symbol          lexhints_maybe :G0_RULESEP expression ruleend_maybe/], rank => 0, action => '_action_rule' },
	      { lhs => 'rule',                    rhs => [qw/:RULENUMBER  symbol          lexhints_maybe :G1_RULESEP expression ruleend_maybe/], rank => 0, action => '_action_rule' },
	      { lhs => 'rule',                    rhs => [qw/:RULENUMBER :SYMBOL__START   lexhints_maybe :G1_RULESEP expression ruleend_maybe/], rank => 0, action => '_action_rule' },
	      { lhs => 'rule',                    rhs => [qw/:RULENUMBER :SYMBOL__DISCARD lexhints_maybe :G0_RULESEP symbol     ruleend_maybe/], rank => 0, action => '_action_rule' },
	      #
	      # /\
	      # || action => [ [ [ [ @rhs ], { hints } ] ] ]
	      # ||
	      # --- #
	      { lhs => 'expression',              rhs => [qw/concatenation more_concatenation_any/],          action => '_action_expression' },
	      { lhs => 'expression_notempty',     rhs => [qw/concatenation_notempty more_concatenation_any/], action => '_action_expression' },
	      # |   #
	      # |   # /\
	      # |   # || action => \%hint_hash or undef
	      # |   # ||
	      # |   #
              { lhs => 'hint',                    rhs => [qw/:RANK :HINT_OP :RANK_VALUE/],         action => '_action_hint_rank' },
              { lhs => 'hint',                    rhs => [qw/:BLESS :HINT_OP :BLESS_VALUE/],       action => '_action_hint_bless' },
              { lhs => 'hint',                    rhs => [qw/:ACTION :HINT_OP :ACTION_VALUE/],     action => '_action_hint_action' },
              { lhs => 'hint',                    rhs => [qw/:ASSOC :HINT_OP :ASSOC_VALUE/],       action => '_action_hint_assoc' },
              { lhs => 'hint_any',                rhs => [qw/hint/], min => 0,                     action => '_action_hint_any' },
              { lhs => 'hints_maybe',             rhs => [qw/hint_any/],                           action => '_action_hints_maybe' },
              { lhs => 'hints_maybe',             rhs => [qw//],                                   action => '_action_hints_maybe' },
              { lhs => 'lexhint',                 rhs => [qw/:PRE :HINT_OP :PRE_VALUE/],           action => '_action_lexhint_pre' },
              { lhs => 'lexhint',                 rhs => [qw/:POST :HINT_OP :POST_VALUE/],         action => '_action_lexhint_post' },
              { lhs => 'lexhint_any',             rhs => [qw/lexhint/], min => 0,                  action => '_action_lexhint_any' },
              { lhs => 'lexhints_maybe',          rhs => [qw/lexhint_any/],                        action => '_action_lexhints_maybe' },
              { lhs => 'lexhints_maybe',          rhs => [qw//],                                   action => '_action_lexhints_maybe' },
	      # |   #
	      # |   # /\
	      # |   # || action => [ [ [ @rhs ], { hints } ] ]
	      # |   # ||
	      # |   #
	      { lhs => 'more_concatenation',      rhs => [qw/:PIPE concatenation/],              action => '_action_more_concatenation' },
	      { lhs => 'more_concatenation_any',  rhs => [qw/more_concatenation/], min => 0,     action => '_action_more_concatenation_any' },
	      # |   #
	      # |   # /\
	      # |   # || action => [ [ @rhs ], { hints } ]
	      # |   # ||
	      # |   #
	      { lhs => 'concatenation',           rhs => [qw/exception_any hints_maybe/],        action => '_action_concatenation' },
	      { lhs => 'concatenation_notempty',  rhs => [qw/exception_many hints_maybe/],       action => '_action_concatenation' },
	      # |   #
	      # |   # /\
	      # |   # || action => [ @rhs ]
	      # |   # ||
	      # |   #
	      { lhs => 'comma_maybe',             rhs => [qw/:COMMA/],                           action => '_action_comma_maybe' },
	      { lhs => 'comma_maybe',             rhs => [qw//],                                 action => '_action_comma_maybe' },

	      { lhs => 'exception_any',           rhs => [qw/exception/], min => 0,              action => '_action_exception_any' },
	      { lhs => 'exception_many',          rhs => [qw/exception/], min => 1,              action => '_action_exception_many' },
	      { lhs => 'exception',               rhs => [qw/term more_term_maybe comma_maybe/], action => '_action_exception' },
	      # |   #
	      # |   # /\
	      # |   # || action => rhs_as_string or undef
	      # |   # ||
	      # |   #
	      { lhs => 'more_term',               rhs => [qw/:MINUS term/],                     action => '_action_more_term' },

	      { lhs => 'more_term_maybe',         rhs => [qw/more_term/],                       action => '_action_more_term_maybe' },
	      { lhs => 'more_term_maybe',         rhs => [qw//],                                action => '_action_more_term_maybe' },

	      { lhs => 'term',                    rhs => [qw/factor/],                          action => '_action_term' },
	      # |   #
	      # |   # /\
	      # |   # || action => quantifier_as_string or undef
	      # |   # ||
	      # |   #
	      { lhs => 'quantifier',              rhs => [qw/:STAR/],                           action => '_action_quantifier' },
	      { lhs => 'quantifier',              rhs => [qw/:PLUS/],                           action => '_action_quantifier' },
	      { lhs => 'quantifier',              rhs => [qw/:QUESTIONMARK/],                   action => '_action_quantifier' },
              { lhs => 'hint_quantifier',         rhs => [qw/:SEPARATOR :HINT_OP symbol/],      action => '_action_hint_quantifier_separator' },
              { lhs => 'hint_quantifier',         rhs => [qw/:PROPER :HINT_OP :PROPER_VALUE/],  action => '_action_hint_quantifier_proper' },
              { lhs => 'hint_quantifier_any',     rhs => [qw/hint_quantifier/], min => 0,       action => '_action_hint_quantifier_any' },
	      { lhs => 'quantifier_maybe',        rhs => [qw/quantifier/],                      action => '_action_quantifier_maybe' },
	      { lhs => 'quantifier_maybe',        rhs => [qw//],                                action => '_action_quantifier_maybe' },
	      # |   #
	      # |   # /\
	      # |   # || action => rhs_as_string or undef
	      # |   # ||
	      # |   #
	      { lhs => 'hexchar_many',            rhs => [qw/:HEXCHAR/], min => 1,              action => '_action_hexchar_many' },
	      #
	      ## Rank 4
	      #  ------
              # Special case of [ { XXX }... ] meaning XXX*, that we want to catch first
              # Special case of [ XXX... ] meaning XXX*, that we want to catch first
	      { lhs => 'factor',                  rhs => [qw/:LBRACKET :LCURLY expression_notempty :RCURLY :PLUS :RBRACKET hint_quantifier_any/], rank => 4, action => '_action_factor_lbracket_lcurly_expression_rcurly_plus_rbracket' },
	      { lhs => 'factor',                  rhs => [qw/:LBRACKET symbol :PLUS :RBRACKET hint_quantifier_any/], rank => 4, action => '_action_factor_lbracket_symbol_plus_rbracket' },
              # Special case of DIGITS * [ XXX ] meaning XXX{0..DIGIT}, that we want to catch first
	      { lhs => 'factor',                  rhs => [qw/:DIGITS :STAR :LBRACKET symbol :RBRACKET/], rank => 4, action => '_action_factor_digits_star_lbracket_symbol_rbracket' },
              # Special case of DIGITS * { XXX } meaning XXX{1..DIGIT}, that we want to catch first
	      { lhs => 'factor',                  rhs => [qw/:DIGITS :STAR :LCURLY symbol :RCURLY/], rank => 4, action => '_action_factor_digits_star_lcurly_symbol_rcurly' },
	      #
	      ## When a symbol is seen as symbol balanced, then no ambiguity.
	      ## But when a symbol is simply a word this is BAD writing of EBNF.
	      ## Therefore, IF your symbol contains '-' it can very well be cached in a CHAR_RANGE in the following
	      ## situation: [ bad-symbol ]
	      ## That's exactly why, when you have an EBNF, you should ALWAYS make sure that
	      ## all symbols are writen with the <> form
	      ## We give higher precedence everywere symbol is in a factor rule and appears in the <> form
	      #
	      { lhs => 'factor',                  rhs => [qw/symbol_balanced quantifier hint_quantifier_any/], rank => 4, action => '_action_factor_symbol_balanced_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/symbol_balanced/], rank => 4, action => '_action_factor_symbol_balanced_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/:DIGITS :STAR symbol_balanced hint_quantifier_any/], rank => 4, action => '_action_factor_digits_star_symbol_balanced' },
	      { lhs => 'factor',                  rhs => [qw/:DIGITS :STAR symbol_balanced/], rank => 4, action => '_action_factor_digits_star_symbol_balanced' },

	      #
	      ## Rank 3
	      #  ------
	      # We want strings to have a higher rank, because in particular a string can contain the MINUS character...
	      { lhs => 'factor',                  rhs => [qw/:STRING quantifier hint_quantifier_any/], rank => 3, action => '_action_factor_string_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/:STRING/], rank => 3, action => '_action_factor_string_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/:DIGITS :STAR :STRING/], rank => 3, action => '_action_factor_digits_star_string' },
	      #
	      ## Rank 2
	      #  ------
	      { lhs => 'factor',                  rhs => [qw/:CARET_CHAR_RANGE quantifier hint_quantifier_any/], rank => 2, action => '_action_factor_caret_char_range_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/:CARET_CHAR_RANGE/], rank => 2, action => '_action_factor_caret_char_range_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/:CHAR_RANGE quantifier hint_quantifier_any/], rank => 2, action => '_action_factor_char_range_quantifier_maybe'},
	      { lhs => 'factor',                  rhs => [qw/:CHAR_RANGE/], rank => 2, action => '_action_factor_char_range_quantifier_maybe'},
	      #
	      ## Rank 1
	      #  ------
	      { lhs => 'factor',                  rhs => [qw/:REGEXP/], rank => 1, action => '_action_factor_regexp' },
	      { lhs => 'factor',                  rhs => [qw/:LPAREN expression_notempty :RPAREN quantifier hint_quantifier_any/], rank => 1, action => '_action_factor_expression_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/:LPAREN expression_notempty :RPAREN/], rank => 1, action => '_action_factor_expression_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/:LCURLY expression_notempty :RCURLY quantifier hint_quantifier_any/], rank => 1, action => '_action_factor_expression_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/:LCURLY expression_notempty :RCURLY/], rank => 1, action => '_action_factor_expression_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/:LBRACKET expression_notempty :RBRACKET/], rank => 1, action => '_action_factor_expression_maybe' },
	      { lhs => 'factor',                  rhs => [qw/:DIGITS :STAR expression_notempty/], rank => 1, action => '_action_factor_digits_star_expression' },
	      { lhs => 'factor',                  rhs => [qw/word quantifier hint_quantifier_any/], rank => 1, action => '_action_factor_word_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/word/], rank => 1, action => '_action_factor_word_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/:DIGITS :STAR word hint_quantifier_any/], rank => 1, action => '_action_factor_digits_star_word' },
	      { lhs => 'factor',                  rhs => [qw/:DIGITS :STAR word/], rank => 1, action => '_action_factor_digits_star_word' },
	      #
	      ## Rank 0
	      #  ------
	      { lhs => 'factor',                  rhs => [qw/hexchar_many quantifier hint_quantifier_any/], rank => 0, action => '_action_factor_hexchar_many_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/hexchar_many/], rank => 0, action => '_action_factor_hexchar_many_quantifier_maybe' },
	     ]
     }
    );
$GRAMMAR->precompute();
#
## We describe in this hash all character escapes of perl that we support.
## Because if a grammar gives a string containing \n it obviously means the single
## character newline, for example.
## C.f. http://perldoc.perl.org/perlrebackslash.html#Character-Escapes
##
## This will be applied to all strings in the "" format and character ranges
## found in the grammar
#  -------------------------------------------------------------------------------
our %CHAR_ESCAPE = ();
foreach (qw/\a \b \e \f \n \r \t/) {
    $CHAR_ESCAPE{quotemeta($_)} = $_;
}
our $CHAR_ESCAPE_CONCAT = join('|', map {quotemeta($_)} keys %CHAR_ESCAPE);
our $CHAR_ESCAPE_RE = qr/([\\]*?)($CHAR_ESCAPE_CONCAT)/;

#
## We describe in this hash all POSIX character classes of perl that we support.
## We support use POSIX bracketed classes, perl shortcuts.
## C.f. http://perldoc.perl.org/perlrecharclass.html#POSIX-Character-Classes
##
## This will be applied to all character ranges found in the grammar
#  -------------------------------------------------------------------------------
our %CHAR_CLASS = ();
foreach (qw/\h \d \s \w/) {
    $CHAR_CLASS{quotemeta($_)} = $_;
}
foreach (qw/alpha alnum ascii blank cntrl digit graph lower print punct space upper word xdigit/) {
    my $class = "[:${_}:]";
    $CHAR_CLASS{quotemeta($class)} = $class;
}
our $CHAR_CLASS_CONCAT = join('|', map {quotemeta($_)} keys %CHAR_CLASS);
our $CHAR_CLASS_RE = qr/([\\]*?)($CHAR_CLASS_CONCAT)/;

#
## Support of Regexp::Common
## C.f. http://perldoc.net/Regexp/Common.pm
##
## This will be applied to regexp //
#  -------------------------------------------------------------------------------
our $REGEXP_COMMON_RE = qr/\$RE($RE{balanced}{-parens=>'{}'}+)/;

#    ----                         ---------------    ------------- -------------
#    Name                         Possible_values    Allow undef   Default_value
#    ----                         ---------------    ------------- -------------
our %OPTION_DEFAULT = (
    'style'                  => [[qw/Moose perl5/], 0, 'perl5'           ],
    'char_escape'            => [undef            , 0, 1                 ],
    'regexp_common'          => [undef            , 0, 1                 ],
    'char_class'             => [undef            , 0, 1                 ],
    'trace_terminals'        => [undef            , 0, 0                 ],
    'trace_values'           => [undef            , 0, 0                 ],
    'trace_actions'          => [undef            , 0, 0                 ],
    'action_failure'         => [undef            , 0, '_action_failure' ],
    'ranking_method'         => [[qw/none rule high_rule_only/], 0, 'high_rule_only' ],
    'default_action'         => [undef            , 1, undef             ],
    'action_object'          => [undef            , 1, undef             ],
    'bless_package'          => [undef            , 1, undef             ],
    'startrules'             => [undef            , 0, [qw/:start/]      ],
    'discardrules'           => [undef            , 0, [qw/:discard/]    ],
    'generated_lhs_format'   => [undef            , 0, 'generated_lhs_%06d' ],
    'generated_action_format'=> [undef            , 0, 'generated_action_%06d' ],
    'generated_token_format' => [undef            , 0, 'GENERATED_TOKEN_%06d' ],
    'default_assoc'          => [[qw/left group right/], 0, 'left'       ],
    # 'position_trace_format'  => [undef            , 0, '[Line:Col %4d:%03d, Offset:offsetMax %6d/%06d] ' ],
    'position_trace_format'  => [undef            , 0, '[%4d:%4d] ' ],
    'infinite_action'        => [[qw/fatal warn quiet/], 0, 'fatal'      ],
    'auto_rank'              => [[qw/0 1/]        , 0, 0                 ],
    'multiple_parse_values'  => [[qw/0 1/]        , 0, 0                 ],
    'longest_match'          => [[qw/0 1/]        , 0, 1                 ],
    'marpa_compat'           => [[qw/0 1/]        , 0, 1                 ],
    );

###############################################################################
# reset_options
###############################################################################
sub reset_options {
    my $self = shift;

    my $rc = {};

    foreach (keys %OPTION_DEFAULT) {
	$rc->{$_} = $self->{$_} = $OPTION_DEFAULT{$_}->[2];
    }

    return $rc;
}

###############################################################################
# new
###############################################################################
sub option_value_is_ok {
    my ($self, $name, $ref, $value) = @_;
    my $possible    = $OPTION_DEFAULT{$name}->[0];
    my $allow_undef = $OPTION_DEFAULT{$name}->[1];

    if (defined($possible) && defined($value)) {
	if (ref($possible) eq 'ARRAY') {
	    if (! grep {"$value" eq "$_"} @{$possible}) {
		croak "Bad option value \"$value\" for $name, should be one of " . join(', ', @{$possible}) . "\n";
	    }
	} elsif (ref($possible) eq 'SCALAR') {
	    if (! grep {"$value" eq "$_"} (${$possible})) {
		croak "Bad option value \"$value\" for $name, must be ${$possible}\n";
	    }
	} elsif (ref($possible) eq '') {
	    if ("$value" ne "$possible") {
		croak "Bad option value \"$value\" for $name, must be $possible\n";
	    }
	} else {
	    croak "Bad configuration inside " . __PACKAGE__ . " for $name, possible values ref is " . ref($possible) . "
\n";
	}
    }
    if (! defined($value)) {
	if (! $allow_undef) {
	    croak "No option value for $name\n";
	}
    } elsif (ref($value) ne $ref) {
	croak "Bad option value for $name (is a " . ref($value) . ", expecting a $ref)\n";
    }
}

###############################################################################
# manage_options
###############################################################################
sub manage_options {
  my ($self, $init_mode, $optp) = @_;

  if (defined($optp) && (ref($optp) ne 'HASH')) {
    croak "Options must be a reference to a hash\n";
  }

  if ($init_mode) {
    foreach (keys %OPTION_DEFAULT) {
      my $value = exists($optp->{$_}) ? $optp->{$_} : $OPTION_DEFAULT{$_}->[2];
      $self->$_($value);
    }
  } elsif (defined($optp)) {
    foreach (keys %{$optp}) {
      if (! exists($OPTION_DEFAULT{$_})) {
        croak "Unknown option $_\n";
      }
      $self->$_($optp->{$_});
    }
  }

}

###############################################################################
# new
###############################################################################
sub new {
    my ($class, $optp) = @_;

    my $self  = {};
    bless($self, $class);

    $self->manage_options(1, $optp);

    return $self;
}

###############################################################################
# make_token_if_not_exist
###############################################################################
sub make_token_if_not_exist {
    my ($self, $closure, $tokensp, $nb_token_generatedp, $token, $orig, $re, $code) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_token_if_not_exist';
    $self->dumparg_in($closure, $orig, $re, $code);

    my @token = grep {$tokensp->{$_}->{orig} eq $orig} keys %{$tokensp};
    if (! @token) {
	if (! defined($token)) {
	    $token = $self->make_token_name($closure, $nb_token_generatedp);
	}
	if ($DEBUG_PROXY_ACTIONS) {
	    $log->debugf('+++ Adding token \'%s\' for %s => %s', $token || '', $orig || '', $re || '');
	}
	$tokensp->{$token} = $self->make_token($closure, $orig, $re, $code, undef, undef);
    } else {
	if (! defined($token)) {
	    $token = $token[0];
	}
    }

    $self->dumparg_out($closure, $token);
    return $token;
}

###############################################################################
# make_token
###############################################################################
sub make_token {
    my ($self, $closure, $orig, $token, $code, $pre, $post) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_token';
    $self->dumparg_in($closure, $orig, $token, $code);

    my $rc = {};
    if (defined($orig)) {
	$rc->{orig} = $orig;
    }
    if (defined($pre)) {
	$rc->{pre} = $pre;
    }
    if (defined($post)) {
	$rc->{post} = $post;
    }
    if (ref($token) eq 'Regexp') {
	$rc->{re} = $token;
	$rc->{code} = $code ||
	    sub {
		# $self = $_[0]
		# $string = $_[1]
		# $line = $_[2]
		# $tokensp = $_[3]
		# $pos = $_[4]
		# $posline = $_[5]
		# $linenb = $_[6]
		# $expected = $_[7]
		# $matchesp = $_[8]
		# $longest_match = $_[9]
		# $token_name = $_[10]
		# $rcp = $_[11]

		if ($_[1] =~ $_[3]->{$_[10]}->{re}) {
		    my $matched_len = $+[0] - $-[0];
		    my $matched_value = substr($_[1], $-[0], $matched_len);
		    ${$_[11]} = [$_[10], \$matched_value, $matched_len];
		    return 1;
		} else {
		    return 0;
		}
	};
    } else {
	$rc->{string} = $token;
	$rc->{string_length} = length($token);
	$rc->{code} = $code ||
	    sub {
		# $self = $_[0]
		# $string = $_[1]
		# $line = $_[2]
		# $tokensp = $_[3]
		# $pos = $_[4]
		# $posline = $_[5]
		# $linenb = $_[6]
		# $expected = $_[7]
		# $matchesp = $_[8]
		# $longest_match = $_[9]
		# $token_name = $_[10]
		# $rcp = $_[11]
		if (substr($_[1], $_[4], $_[3]->{$_[10]}->{string_length}) eq $_[3]->{$_[10]}->{string}) {
		    ${$_[11]} = [$_[10], \$_[3]->{$_[10]}->{string}, $_[3]->{$_[10]}->{string_length}];
		    return 1;
		} else {
		    return 0;
		}
	};
    }

    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# make_token_name
###############################################################################
sub make_token_name {
    my ($self, $closure, $nb_token_generatedp) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_token_name';
    $self->dumparg_in($closure, $nb_token_generatedp);

    my $rc = sprintf($self->generated_token_format, ++$$nb_token_generatedp);

    #
    ## We remember this was a generated LHS for the dump
    ## in case of multiple parse tree
    #
    $self->{generated_token}->{$rc}++;

    $self->dumparg_out($closure, $rc);

    return $rc;
}

###############################################################################
# make_lhs_name
###############################################################################
sub make_lhs_name {
    my ($self, $closure, $nb_lhs_generatedp) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_lhs_name';
    $self->dumparg_in($closure, $nb_lhs_generatedp);

    my $rc = sprintf($self->generated_lhs_format, ++$$nb_lhs_generatedp);

    #
    ## We remember this was a generated LHS for the dump
    ## in case of multiple parse tree
    #
    $self->{generated_lhs}->{$rc}++;

    $self->dumparg_out($closure, $rc);

    return $rc;
}

###############################################################################
# make_action_name
###############################################################################
sub make_action_name {
    my ($self, $closure, $nb_action_generatedp) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_action_name';
    $self->dumparg_in($closure, $nb_action_generatedp);

    my $rc = sprintf($self->generated_action_format, ++$$nb_action_generatedp);

    #
    ## We remember this was a generated ACTION for the dump
    ## in case of multiple parse tree
    #
    $self->{generated_action}->{$rc}++;

    $self->dumparg_out($closure, $rc);

    return $rc;
}

###############################################################################
# is_internal_action
###############################################################################
sub is_internal_action {
    my ($self, $action) = @_;

    my $rc = 0;
    if (defined($action) && (index($action, $INTERNAL_MARKER) == $[)) {
	$rc = 1;
    }
    return $rc;
}

###############################################################################
# is_external_action
###############################################################################
sub is_external_action {
    my ($self, $action) = @_;

    my $rc = 0;
    if (defined($action) && (index($action, $INTERNAL_MARKER) != $[)) {
	$rc = 1;
    }
    return $rc;
}

###############################################################################
# push_rule
###############################################################################
sub push_rule {
    my ($self, $closure, $arrayp, $lhs, $rhsp, $min, $proper, $separator, $rank, $action, $bless) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'push_rule';
    #
    ## If $action is not an internal action, then we deref, because we always return
    ## a reference to an array in our internal actions
    #
    my $this = {lhs => $lhs, rhs => $rhsp, min => $min, proper => $proper, separator => $separator, rank => $rank, action => $action, bless => $bless};
    $self->dumparg_in($closure, $this);
    my $rc = $lhs;
    push(@{$arrayp}, $this);
    $self->dumparg_in($closure, $rc);

    return $rc;  
}

###############################################################################
# add_rule
###############################################################################
sub add_rule {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $h) = @_;

    $closure ||= '';
    $closure =~ s/\w+/  /;
    $closure .= 'add_rule';
    $self->dumparg_in($closure, $h);

    my $lhs = $h->{lhs};
    my $min       = (exists($h->{min})       && defined($h->{min}))       ? $h->{min}    : undef;
    my $rank      = (exists($h->{rank})      && defined($h->{rank}))      ? $h->{rank}   : undef;
    my $action    = (exists($h->{action})    && defined($h->{action}))    ? $h->{action} : undef;
    my $bless     = (exists($h->{bless})     && defined($h->{bless}))     ? $h->{bless} : undef;
    my $proper    = (exists($h->{proper})    && defined($h->{proper}))    ? $h->{proper} : undef;
    my $separator = (exists($h->{separator}) && defined($h->{separator})) ? $h->{separator} : undef;

    #
    ## If we refer a token, RHS will be the generated token
    #
    my $token = undef;
    if (exists($h->{re}) || exists($h->{string})) {
	my @token = grep {$tokensp->{$_}->{orig} eq $h->{orig}} keys %{$tokensp};
	if (! @token) {
	    $token = $self->make_token_name($closure, $nb_token_generatedp);
            if ($DEBUG_PROXY_ACTIONS) {
		$log->debugf('+++ Adding token \'%s\' of type %s for %s', $token || '', exists($h->{re}) ? 'regexp' : 'string', $h->{orig} || '');
	    }
	    $tokensp->{$token} = $self->make_token($closure, $h->{orig}, exists($h->{re}) ? $h->{re} : $h->{string}, $h->{code});
	} else {
	    $token = $token[0];
	}
	#
	## If there is no min then this is strictly equivalent to the token
	#
	if (! defined($min)) {
	    return $token;
	}
    }
    #
    ## If action begins with '{' then this is an anonymous action.
    #
    if (defined($action) && substr($action, $[, 1) eq '{') {
	my $action_name = $self->make_action_name($closure, $nb_action_generatedp);
	if ($DEBUG_PROXY_ACTIONS) {
	    $log->debugf('+++ Adding action \'%s\'', $action_name);
	}
	$actionsp->{$action_name}->{orig} = $action;
	$actionsp->{$action_name}->{code} = eval "sub $action";
	if ($@) {
	    croak "Failure to evaluation action $action\n";
	}
	$action = $action_name;
    }
    #
    ## $h->{rhs} is usually undef if we associate a token with the LHS
    #
    my $rhsp = $h->{rhs} || (defined($token) ? [ $token ] : (defined($lhs) ? [ $lhs ] : []));
    my @okrhs = grep {defined($_)} @{$rhsp};
    $rhsp = \@okrhs;

    if (! defined($lhs)) {
        #
        ## Automatically generated LHS
        #
        $lhs = $self->make_lhs_name($closure, $nb_lhs_generatedp);
    }

    if (! defined($rulesp->{$lhs})) {
        $rulesp->{$lhs} = [];
    }
    #
    ## In case a we are adding a rule that consists strictly to a quantifier token, e.g.:
    ## SYMBOL ::= TOKEN <quantifier>
    ## and if this TOKEN has never been used before, then we revisit the token by adding
    ## this quantifier, removing all intermediary steps
    #
    if ($DEBUG_PROXY_ACTIONS) {
      $log->debugf('+++ Adding rule {lhs => \'%s\', rhs => [\'%s\'], min => %s, action => %s, bless => %s, proper => %s, separator => %s, rank => %s}',
		   $lhs,
		   join('\', \'', @{$rhsp}),
		   defined($min) ? $min : 'undef',
		   defined($action) ? $action : 'undef',
		   defined($bless) ? $bless : 'undef',
		   defined($proper) ? $proper : 'undef',
		   defined($separator) ? $separator : 'undef',
		   defined($rank) ? $rank : 'undef');
    }
    my $rc = $lhs;
    #
    ## Marpa does not like nullables that are on the rhs of a counted rule
    ## - We nevertheless continue to use the normal min => 0 if:
    ## - there is a single RHS
    ## - the LHS is not a counted rule
    #
    if (defined($min) && ($min == 0) ) {
	## So if min is 0, instead of doing:
	##
	## rule => [ @rhs ],  min => 0, action => $action, rank => $rank
	## with, in input to the action, an array of rules: @rule
	##
	## we do:
	##
	## rule => [ @rhs ]
	## rule* -> rule
	## rule* -> rule* rule
	## rule* -> <EMPTY>
	##
	## The only problem is that this will create two parse trees. So we introduce a preference:
	## rule*    ::= rule* rule
	##           || rule
        ##           || ;
	##
	## And because we want to respect the eventual action and rank of the original that was:
	## rule => [ @rhs ], action => $action, rank => $rank
	##
	## we create another fake rule that will make sure all arguments are ordered as in min => 0
	## fake => rule* , action => $ACTION_MAKE_ARRAYP, rank => $rank
	##
	## If there is no action, then we have finished to mimic the default behaviour.
	##
	## But if there is an action, we have to reference it with an argument of the type
	## returned by $ACTION_MAKE_ARRAYP. Then we create a "final" rule:
	## final => fake , action => $action, rank => $rank
	##
	## This allow us the mimic the exact behaviour of actions arguments of an original
	## Marpa setup with:
	## rule => [ @rhs ], min => 0, action => $action, rank => $rank
	## i.e. a reference to an array of references
        ##
        ## We have full control on $lhsmin0 but not on $lhs, therefore we create another fake lhs: $lhsdup
        ##
	## Many thanks to rns (google group marpa-parser)
	#
	## This is the original rule, but without the min => 0
	## action will return [ original_output ]
        #
	$self->push_rule($closure, $rulesp->{$lhs}, $lhs, $rhsp, undef, $proper, $separator, undef, $ACTION_ARGS, undef);
        #
        ## action will return [ original_output ]
        #
	my $lhsdup = $self->make_lhs_name($closure, $nb_lhs_generatedp);
	$self->push_rule($closure, $rulesp->{$lhs}, $lhsdup, [ $lhs ], undef, undef, undef, undef, $ACTION_FIRST_ARG, undef);

	my $lhsmin0 = $self->make_lhs_name($closure, $nb_lhs_generatedp);
	my $lhsfake = $self->make_lhs_name($closure, $nb_lhs_generatedp);
	$self->make_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $lhsmin0,
			 [
			  #
			  ## rule*    ::= rule* rule
			  #
			  #   [ x ], [ y ]          => [ [ x ], [ y ] ]
			  # [ [ x ], [ y ] ], [ z ] => [ [ x ], [ y ], [ z ] ]
                          #
                          ##                                         action will return [ [ original_output1 ], [ original_output2 ], ... [ original_output ] ]
                          #
			  [ undef, [ [ $lhsmin0 ] , [ $lhsdup ] ], { action => $ACTION_TWO_ARGS_RECURSIVE } ],
			  [
			   #
			   ##         || rule
			   #
			   # x => [ x ]                              action will return [ original_output ]
                           #
			   [ '|',  [                [ $lhsdup ] ], { action => $ACTION_TWO_ARGS_RECURSIVE } ],
			   #
			   ##         ||
			   #
			   # x => [ ]                             action will return []
                           #
			   [ '||', [                         ], { action => $ACTION_WHATEVER } ]
			  ]
			 ]
	    );
	#
	## This is the fake rule that make sure that the output of rule* is always in the form [ [...], [...], ... ]
	## action will return [ [ original_output1 ], [ original_output2 ], ... [ original_output ] ]
	$self->push_rule($closure, $rulesp->{$lhs}, $lhsfake, [ $lhsmin0 ], undef, undef, undef, undef, $ACTION_FIRST_ARG, undef);

	if (defined($action)) {
	    my $lhsfinal = $self->make_lhs_name($closure, $nb_lhs_generatedp);
	    $rc = $lhsfinal;
	    #
	    ## This is the final rule that mimic the arguments min => 0 would send. Last, because we changed the
	    ## semantics we will have to use a proxy action that we dereference [ [ @return1 ], [ @return2 ] ] to
	    ## @return1, @return2
	    #
	    $self->push_rule($closure, $rulesp->{$lhs}, $lhsfinal, [ $lhsfake ], undef, undef, undef, $rank, $action, $bless);
	} else {
	    $rc = $lhsfake;
	}
    } elsif (defined($min) && ($min == -1) ) {
	# Question mark
 	$self->push_rule($closure, $rulesp->{$lhs}, $lhs, $rhsp, undef, $proper, $separator, $rank, $action, $bless);
 	$self->push_rule($closure, $rulesp->{$lhs}, $lhs, [], undef, $proper, $separator, $rank, $action, $bless);
    } else {
 	$self->push_rule($closure, $rulesp->{$lhs}, $lhs, $rhsp, $min, $proper, $separator, $rank, $action, $bless);
    }

    $self->dumparg_out($closure, $rc);

    return $rc;
}

###############################################################################
# range_to_r1_r2
###############################################################################
sub range_to_r1_r2 {
    my ($self, $re, $rc) = @_;

    #
    ## Quoted from perldoc perlre:
    #
    ## You can specify a character class, by enclosing a list of characters in [] , which will match any character from the list. If the first character after the "[" is "^", the class matches any character not in the list. Within a list, the "-" character specifies a range, so that a-z represents all characters between "a" and "z", inclusive. If you want either "-" or "]" itself to be a member of a class, put it at the start of the list (possibly after a "^"), or escape it with a backslash. "-" is also taken literally when it is at the end of the list, just before the closing "]". (The following all specify the same class of three characters: [-az] , [az-] , and [a\-z] . All are different from [a-z] , which specifies a class containing twenty-six characters, even on EBCDIC-based character sets.) Also, if you try to use the character classes \w , \W , \s, \S , \d , or \D as endpoints of a range, the "-" is understood literally.
    ##
    # Note also that the whole range idea is rather unportable between character sets--and even within character sets they may cause results you probably didn't expect. A sound principle is to use only ranges that begin from and end at either alphabetics of equal case ([a-e], [A-E]), or digits ([0-9]). Anything else is unsafe. If in doubt, spell out the character sets in full.
    ##
    #
    $rc =~ $re;

    my $r1 = substr($rc, $-[2], $+[2] - $-[2]);
    my $r2 = defined($-[3]) ? substr($rc, $-[3], $+[3] - $-[3]) : '';
    if ($r1 =~ $TOKENS{HEXCHAR}->{re}) {
	$r1 = '\\x{' . substr($r1, $-[2], $+[2] - $-[2]) . '}';
    }
    if (length($r2) > 0) {
	if ($r2 =~ $TOKENS{HEXCHAR}->{re}) {
	    $r2 = '\\x{' . substr($r2, $-[2], $+[2] - $-[2]) . '}';
	}
    }

    return($r1, $r2);
};


###############################################################################
# range_to_r1_r2_v2
# perl implementation of perl5's regclass found in regcomp.c
###############################################################################
sub range_to_r1_r2_v2 {
    my ($self, $re, $range) = @_;

    #
    ## Quoted from perldoc perlre:
    #
    ## You can specify a character class, by enclosing a list of characters in [] ,
    ## which will match any character from the list. If the first character after the "[" is "^",
    ## the class matches any character not in the list. Within a list, the "-" character specifies
    ## a range, so that a-z represents all characters between "a" and "z", inclusive. If you want
    ## either "-" or "]" itself to be a member of a class, put it at the start of the list (possibly after a "^"),
    ## or escape it with a backslash. "-" is also taken literally when it is at the end of the list, just
    ## before the closing "]". (The following all specify the same class of three characters: [-az] , [az-] , and [a\-z] .
    ## All are different from [a-z] , which specifies a class containing twenty-six characters, even on EBCDIC-based character sets.)
    ## Also, if you try to use the character classes \w , \W , \s, \S , \d , or \D as endpoints of a range,
    ## the "-" is understood literally.
    ##
    ## Note also that the whole range idea is rather unportable between character sets--and even within character sets
    ## they may cause results you probably didn't expect. A sound principle is to use only ranges that begin from and
    ## end at either alphabetics of equal case ([a-e], [A-E]), or digits ([0-9]). Anything else is unsafe.
    ## If in doubt, spell out the character sets in full.
    ##
    #
    my $first = substr($range, $[, 1, '');
    my $last  = substr($range, BEGSTRINGPOSMINUSONE, 1, '');
    if ($first ne '[' || $last ne ']') {
      croak "Range must be enclosed with [] characters, not with $first$last\n";
    }
    my $is_caret = (substr($range, $[, 1) eq '^') ? 1 : 0;
    if ($is_caret) {
      substr($range, $[, 1) = '';
    }
    #if (length($range) <= 0) {
    #  croak "Range ¨$first$range$last must not be empty\n";
    #}

    #
    ## We scan character per character
    #
    my $i;
    my $lasti = length($range) - 1;
    my @c = ();
    my $inrange = 0;
    for ($i = $[; $i <= $lasti; ++$i) {
      my $c = substr($range, $i, 1);
      if (($i == $[) && ($c eq '-' || $c eq  ']')) {          # - or ] is at the start of the list
        push(@c, $c);
        next;
      }
      if ($c eq '-') {
        $inrange = 1;
        next;
      }
      if ($c eq '\\') {                                       # backslash character
        if ($i == $lasti) {
          croak "Escaped character followed by nothing in range $first$range$last\n";
        }
         $c = substr($range, ++$i, 1) || '';
        if (($c eq 'w' || $c eq 'W' || $c eq 's' || $c eq 'S' || $c eq 'd' || $c eq 'D') && $inrange) {
          # endpoint is \w , \W , \s, \S , \d , or \D : '-' is taken literally
          push(@c, '-');
          $inrange = 0;
        }
      }
    }

    return(undef, undef);
};

###############################################################################
# regclass
# This is nothing else but the perl's original regclass rewritten in perl
###############################################################################
sub regclass {
}

###############################################################################
# dumparg
###############################################################################
sub dumparg {
    my $self = shift;
    if ($DEBUG_PROXY_ACTIONS && ref($self) eq __PACKAGE__) {
      __PACKAGE__->_dumparg(@_);
    }
};


###############################################################################
# dumparg_in
###############################################################################
sub dumparg_in {
    my $self = shift;
    my $prefix = shift || '';
    return $self->dumparg("==> $prefix", @_);
};


###############################################################################
# dumparg_out
###############################################################################
sub dumparg_out {
    my $self = shift;
    my $prefix = shift || '';
    return $self->dumparg("<== $prefix", @_);
};


###############################################################################
# _dumparg
###############################################################################
sub _dumparg {
    my $class = shift;
    my $prefix = shift || '';
    my $string = '';
    if (@_) {
      my $d = Data::Dumper->new(\@_);
      $d->Terse(1);
      $d->Indent(0);
      $string = $d->Dump;
    }
    my $rule_id = $Marpa::R2::Context::rule;
    my $g = $Marpa::R2::Context::grammar;
    my $what = '';
    my $lhs = '';
    my @rhs = ();
    if (defined($rule_id) && defined($g)) {
      my ($lhs, @rhs) = $g->rule($rule_id);
      $what = sprintf('{lhs => %s, rhs => [\'%s\']} ', $lhs, join('\, \'', @rhs));
    }
    $log->debugf('%s%s %s', $what, $prefix, $string);
};


###############################################################################
# make_symbol
###############################################################################
sub make_symbol {
    my ($self, $closure, $symbol) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_symbol';
    $self->dumparg_in($closure, $symbol);

    # From: Marpa::R2::Grammar
    #
    # Marpa reserves, for its internal use, all symbol names ending with one of
    # these four symbols: the right square bracket ("]"), the right parenthesis (")"),
    # the right angle bracket (">"), and the right curly bracket ("}"). Any other
    # valid Perl string is an acceptable symbol name.
    #

    my $rc = $symbol;
    $rc =~ s/[\]\)>\}]/_/g;

    $self->dumparg_out($closure, $rc);
    return $rc;
};


###############################################################################
# make_concat
###############################################################################
sub make_concat {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $hintsp, @rhs) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_concat';
    $self->dumparg_in($closure, $hintsp, @rhs);

    #
    ## If:
    ## - there is a single rhs
    ## - there is no min
    ##
    ## then we are asked for an LHS that is strictly equivalent to the single RHS
    #
    my @okrhs = grep {defined($_)} @rhs;
    my $rc = undef;
    if (
	$#okrhs == 0 &&
	! exists($hintsp->{min})) {
	$rc = $okrhs[0];
    } elsif ($#okrhs >= 0) {
	$rc = $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, {rhs => [ @okrhs ], %{$hintsp}});
    }
    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# is_plus_quantifier
###############################################################################
sub is_plus_quantifier {
    my ($self, $closure, $quantifier)  = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'is_plus_quantifier';
    $self->dumparg_in($closure, $quantifier);
    my $rc = (defined($quantifier) && (($quantifier eq $TOKENS{PLUS_01}->{string}) || ($quantifier eq $TOKENS{PLUS_02}->{string}))) ? 1 : 0;
    $self->dumparg_out($closure, $rc);

    return $rc;

}

###############################################################################
# is_star_quantifier
###############################################################################
sub is_star_quantifier {
    my ($self, $closure, $quantifier)  = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'is_star_quantifier';
    $self->dumparg_in($closure, $quantifier);
    my $rc = (defined($quantifier) && ($quantifier eq $TOKENS{STAR}->{string})) ? 1 : 0;
    $self->dumparg_out($closure, $rc);

    return $rc;

}

###############################################################################
# is_questionmark_quantifier
###############################################################################
sub is_questionmark_quantifier {
    my ($self, $closure, $quantifier)  = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'is_questionmark_quantifier';
    $self->dumparg_in($closure, $quantifier);
    my $rc = (defined($quantifier) && ($quantifier eq $TOKENS{QUESTIONMARK}->{string})) ? 1 : 0;
    $self->dumparg_out($closure, $rc);

    return $rc;

}

###############################################################################
# make_factor_expression_quantifier_maybe
###############################################################################
sub make_factor_expression_quantifier_maybe {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $expressionp, $hintsp) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_factor_expression_quantifier_maybe';
    $self->dumparg_in($closure, $expressionp, $hintsp);
    #
    ## We make a rule out of this expression
    #
    my $lhs = $self->make_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, undef, $expressionp);
    #
    ## And we quantify it
    #
    my $rc = $self->make_factor_quantifier_maybe($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, undef, $lhs, $hintsp);

    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# make_factor_char_range_quantifier_maybe
###############################################################################
sub make_factor_char_range_quantifier_maybe {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $range, $range_type, $hintsp) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_factor_range_quantifier_maybe';
    $self->dumparg_in($closure, $range, $range_type, $hintsp);

    my $orig = my $string = $range;
    my ($r1, $r2) = $self->range_to_r1_r2($TOKENS{$range_type}->{re}, $string);
    my $have_char_escape = 0;
    if ($self->char_escape) {
	$have_char_escape += $self->handle_meta_character($closure, \$r1, $CHAR_ESCAPE_RE, \%CHAR_ESCAPE);
	$have_char_escape += $self->handle_meta_character($closure, \$r2, $CHAR_ESCAPE_RE, \%CHAR_ESCAPE);
    }

    my $have_char_class = 0;
    if ($self->char_class) {
	$have_char_class += $self->handle_meta_character($closure, \$r1, $CHAR_CLASS_RE, \%CHAR_CLASS);
	$have_char_class += $self->handle_meta_character($closure, \$r2, $CHAR_CLASS_RE, \%CHAR_CLASS);
    }

    my $rc;
    $hintsp ||= {};

    my $forced_quantifier = '';
    my $orig_quantifier_maybe = '';
    if (exists($hintsp->{orig_quantifier_maybe})) {
	$orig_quantifier_maybe = $hintsp->{orig_quantifier_maybe};
	#
	## Marpa compatibility layer with regular expressions
	#
	if ($self->marpa_compat) {
	    if ($self->is_star_quantifier($closure, $orig_quantifier_maybe)) {
		$forced_quantifier = '*';
		if (exists($hintsp->{min})) {
		    delete($hintsp->{min});
		}
	    } elsif ($self->is_plus_quantifier($closure, $orig_quantifier_maybe)) {
		$forced_quantifier = '+';
		if (exists($hintsp->{min})) {
		    delete($hintsp->{min});
		}
	    }
	}
    }

    if ($DEBUG_PROXY_ACTIONS && $forced_quantifier) {
	if ($range_type eq 'CHAR_RANGE') {
	    if (length($r2) > 0) {
		$log->debugf("Marpa compatibility: moving $orig_quantifier_maybe after [${r1}-${r2}]");
	    } else {
		$log->debugf("Marpa compatibility: moving $orig_quantifier_maybe after [${r1}]");
	    }
	} else {
	    if (length($r2) > 0) {
		$log->debugf("Marpa compatibility: moving $orig_quantifier_maybe after [^${r1}-${r2}]");
	    } else {
		$log->debugf("Marpa compatibility: moving $orig_quantifier_maybe after [^${r1}]");
	    }
	}
    }

    my $re;
    if ($range_type eq 'CHAR_RANGE') {
	$re = (length($r2) > 0) ? qr/\G(?:[${r1}-${r2}]${forced_quantifier})/ms : qr/\G(?:[${r1}]${forced_quantifier})/ms;
    } else {
	$re = (length($r2) > 0) ? qr/\G(?:[^${r1}-${r2}]${forced_quantifier})/ms : qr/\G(?:[^${r1}]${forced_quantifier})/ms;
    }
    $rc = $self->make_factor_quantifier_maybe($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $range, $re, $hintsp);

    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# make_factor_string_quantifier_maybe
###############################################################################
sub make_factor_string_quantifier_maybe {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $string, $hintsp) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_factor_string_quantifier_maybe';
    $self->dumparg_in($closure, $string, $hintsp);

    $hintsp ||= {};
    $hintsp->{token_type} = TOKEN_TYPE_STRING;

    my $orig = $string;
    my $value = $string;
    my $quotetype = substr($value, $[, 1, '');
    substr($value, BEGSTRINGPOSMINUSONE, 1) = '';
    if ($self->char_escape && $quotetype eq '"') {
	$value = eval $value;
    }
    my $rc;

    $rc = $self->make_factor_quantifier_maybe($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $string, $value, $hintsp);

    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# make_factor_symbol_quantifier_maybe
###############################################################################
sub make_factor_symbol_quantifier_maybe {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $symbol, $hintsp) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_factor_symbol_quantifier_maybe';
    $self->dumparg_in($closure, $symbol, $hintsp);

    my $rc = $self->make_factor_quantifier_maybe($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $symbol, $symbol, $hintsp);

    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# make_factor_quantifier_maybe
###############################################################################
sub make_factor_quantifier_maybe {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $orig, $factor, $hintsp) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_factor_quantifier_maybe';
    $self->dumparg_in($closure, $factor, $hintsp);

    $hintsp ||= {};

    my $rc;
    if (ref($factor) eq 'Regexp' || (exists($hintsp->{token_type}) && ($hintsp->{token_type} == TOKEN_TYPE_STRING))) {
	if (ref($factor) eq 'Regexp') {
	    $rc = $self->make_re($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $hintsp, $orig, $factor);
	} else {
	    $rc = $self->make_string($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $hintsp, $orig, $factor);
	}
    } else {
	if (exists($hintsp->{min})) {
	    my @rhs = ref($factor) eq 'ARRAY' ? @{${factor}} : ( ${factor} );
	    if (exists($hintsp->{min}) && ($hintsp->{min} == 0)) {
		$rc = $self->make_concat($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $hintsp, @rhs);
	    } elsif (exists($hintsp->{min}) && ($hintsp->{min} == 1)) {
		$rc = $self->make_concat($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $hintsp, @rhs);
	    } elsif (exists($hintsp->{min}) && ($hintsp->{min} == -1)) {
		$rc = $self->make_maybe($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, @rhs);
	    } else {
		$rc = $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, {rhs => [ (($factor) x $hintsp->{min}) ]});
	    }
	} else {
	    $rc = $factor;
	}
    }

    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# make_any
# Take care, here @rhsp is an array of @rhs
###############################################################################
sub make_any {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, @rhs) = @_;

    $closure ||= '';
    $closure =~ s/\w+/  /;
    $closure .= 'make_any';
    $self->dumparg_in($closure, @rhs);

    #
    ## if there is a single rhs we are not forced to generate an lhs
    #
    my @okrhs = grep {defined($_)} @rhs;
    my $rc = undef;
    if ($#okrhs == 0) {
	$rc = $okrhs[0];
    } else {
	foreach (@okrhs) {
	    $rc = $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, {lhs => $rc, rhs => [ $_ ]});
	}
    }
    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# make_maybe
###############################################################################
sub make_maybe {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $factor) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_maybe';

    $self->dumparg_in($closure, $factor);

    my $rc = $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, {rhs => [ $factor ]});
    $rc = $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, {lhs => $rc, rhs => [ qw// ]});

    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# make_re
###############################################################################
sub make_re {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $hintsp, $orig, $re) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_re';
    $self->dumparg_in($closure, $orig, $re, $hintsp);

    $hintsp ||= {};

    my $rc = $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, {orig => $orig,
																       re => $re,
																       %{$hintsp}});
    
    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# make_string
###############################################################################
sub make_string {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $hintsp, $orig, $string) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_string';
    $self->dumparg_in($closure, $orig, $string, $hintsp);

    $hintsp ||= {};

    my $rc = $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, {orig => $orig,
																       string => $string,
																       %{$hintsp}});

    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# handle_meta_character
###############################################################################
sub handle_meta_character {
    my ($self, $closure, $quoted_stringp, $re, $hashp) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'handle_meta_character';

    $self->dumparg_in($closure, ${$quoted_stringp}, $re);

    #
    ## We restore the quoted escape characters to their unquoted representation
    #
    ## After quotemeta, a \x is now \\x
    ## And this is really a meta character if it was not preceeded by '\\', quotemeta'ed to '\\\\'
    #

    my $rc;
    if (${$quoted_stringp} =~ s/$re/my $m1 = substr(${$quoted_stringp}, $-[1], $+[1] - $-[1]) || ''; my $m2 = substr(${$quoted_stringp}, $-[2], $+[2] - $-[2]); if (exists($hashp->{$m2}) && (length($m1) % 4) == 0) {$m1 . $hashp->{$m2}} else {$m1 . $m2}/eg) {
      $rc = 1;
    } else {
      $rc = 0;
    }

    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# handle_regexp_common
###############################################################################
sub handle_regexp_common {
    my ($self, $closure, $string) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'handle_regexp_common';

    $self->dumparg_in($closure, $string);

    my $rc = $string;
    if ($string =~ /$REGEXP_COMMON_RE/) {
	my $match = substr($string, $-[0] , $+[0] - $-[0]);
	my $re = eval $match;
	if ($@) {
	    croak("Cannot eval $match, $@");
	}
	$rc = qr/$re/ms;
    }

    $self->dumparg_out($closure, $rc);

    return $rc;
}

###############################################################################
# char_class_re
###############################################################################
sub char_class_re {
    my ($self, $runtime_char_class) = @_;

    my $char_class_concat = join('|', map {quotemeta($_)} keys %{$runtime_char_class});
    my $char_class_re = qr/([\\]*?)($char_class_concat)/ms;

    return $char_class_re;
}

###############################################################################
# make_rule
###############################################################################
sub make_rule {
    my $self = shift;
    my ($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, $symbol, $expressionp) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_rule';

    $self->dumparg_in($closure, $symbol, $expressionp);

    #
    ## We always create a symbol if none yet, the return value of make_rule will be this symbol
    #
    $symbol ||= $self->make_lhs_name($closure, $nb_lhs_generatedp);
    #
    ## For the empty rule: expressionp defaults to ''
    #
    if (! defined($expressionp) || ! @{$expressionp}) {
	#
	## Empty rule
	#
	$self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, {lhs => $symbol, rhs => [], action => $ACTION_ARGS});
    } else {
	my @expression = @{$expressionp};
	my $expression = shift(@expression);
	#
	## The first concatenation is:[ undef, [ @rhs ], { hints } ] (c.f. action_more_concatenation)
	#
	my (undef, $rhsp, $hintsp) = @{$expression};
	#
	## 1. All expressions are grouped using the || as a separator
	#  ----------------------------------------------------------
	my @groups = ( [ [ $rhsp, $hintsp ] ] );
	if (@expression) {
	    my @more_expression = @{$expression[0]};
	    foreach (@more_expression) {
		#
		## Can happen if we hitted more_concatenation_any
		#
		next if (! defined($_));
		my ($pipe, $rhsp, $hintsp) = @{$_};
		if ($pipe eq '||') {
		    push(@groups, [] );
		}
		push(@{$groups[-1]}, [ $rhsp, $hintsp ] );
	    }
	}
	#
	## 1. Automatic ranking or rank => xxx
	## -----------------------------------
	## During the grammar actions, we made sure that if option auto_rank is on
	## then it is impossible to have specified rank => xxx.
	## In case of automatic ranking, any new expression get a rank of --"current rank"
	## Otherwise expression get the rank given by rank => xxx or undef
	#
	
	my $i = 0;
	#
	## Take care: we scan the groups in reverse, so that we start with group0 that is in reality the last group
	## C.f. comment below
	#
	my $quotesymbol = quotemeta($symbol);
	my $firstsymbol = $symbol. '_0';
	foreach (reverse @groups) {
	    my $group = $_;
	    my $rank = $self->auto_rank ? 0 : undef;
	    my $symboli = $symbol. '_' . $i;
	    my $symbol_i_plus_one = ($i == $#groups) ? $symbol . '_0' : $symbol . '_' . ($i + 1);
	    if ($#groups > 0) {
		if ($i == 0) {
		    #
		    ## symbol  ::= symbol(0)
		    ## ^^^^^^      ^^^^^^^^^
		    #
		    $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, {lhs => $symbol, rhs => [ $symboli ], action => $ACTION_FIRST_ARG});
		}
		if ($i < $#groups) {
		    #
		    ## symbol(n) ::= symbol(n+1) | groups(n)
		    ## ^^^^^^^^^     ^^^^^^^^^^^
		    #
		    $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, {lhs => $symboli, rhs => [ $symbol_i_plus_one ], action => $ACTION_FIRST_ARG});
		    #
		    ## We apply precedence hooks as in Marpa's Stuifzand, i.e.:
		    ##
		    ## symbol  ::= groups(2)
		    ##           | groups(1)
		    ##           | groups(0)
		    ##
		    ## becomes:
		    ##
		    ## If assoc == 'left'
		    ##
		    ## symbol  ::= symbol0
		    ## symbol0 ::= symbol1 | groups(0)      where, in group(0), 1st symbol becomes A=symbol0, others becomes B=symbol1
		    ## symbol1 ::= symbol2 | groups(1)      where, in group(1), 1st symbol becomes A=symbol1, others becomes B=symbol2
		    ## symbol2 ::= groups(2)                where, in group(2), 1st symbol becomes A=symbol2, others becomes B=symbol0
		    ##
		    ## If assoc == 'group'                      in any group, A=B=symbol0
		    ##
		    ## If assoc == 'right'                      in any group, A and B are switched
		    ##
		    #
		}
		{
		    #
		    ## Because group(n) is a composite thing, each of them can have its own action, we always create a single rule
		    ## symbol(n)_group ::= symbol(n)_group(0) | symbol(n)_group(1) | ... | symbol(n)_group($#{$group})
		    ## where
		    ## symbol(n)_group(x) ::= rhs_of_group(n)(x) action => action_of_group(n)(x)
		    #
		    ## so finally this becomes:
		    ##
		    ## symbol  ::= symbol0
		    ## symbol0 ::= symbol1 | symbol0_group
		    ## symbol1 ::= symbol2 | symbol1_group
		    ## symbol2 ::= symbol2_group
		    ##
		    #
		    my $symboli_group = $symboli . '_group';
		    foreach (0..$#{$group}) {
			#
			## group(n) is replaced by
			## symbol(n)_group ::= symboln_group0
			##                   | symboln_group1
			##                   | ...
			##                   | symboln_group($#{$group})
			##
			## where
			## symboln_groupx ::= group(n)(x)     action => action_of_group(n)(x)
			#
			my $x = $_;
			my ($rhsp, $hintsp) = @{$group->[$x]};
			my @rhs = defined($rhsp) ? (@{$rhsp} ? map {$_->[0]} @{$rhsp} : ()) : ();
			if ($self->auto_rank) {
			    $hintsp->{rank} = $rank--;
			}
			my @newrhs = ();
			my $assoc = exists($hintsp->{assoc}) ? $hintsp->{assoc} : $self->default_assoc;
			my $current_replacement;
			my $after;
			if ($assoc eq 'left') {
			    $current_replacement = $symboli;
			    $after = $symbol_i_plus_one;
			} elsif ($assoc eq 'right') {
			    $current_replacement = $symbol_i_plus_one;
			    $after = $symboli;
			} else {
			    $current_replacement = $after = $symbol. '_0';
			}
			foreach (@rhs) {
			    if (s/^$quotesymbol$/$current_replacement/) {
				$current_replacement = $after;
			    }
			    push(@newrhs, $_);
			}
			$self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, {lhs => $symboli_group, rhs => [ @newrhs ], %{$hintsp}});
		    }
		    #
		    ## We replace entirelly $group[$i] by a single entry: [ $symboli_group, { action => $ACTION_FIRST_ARG } ]
		    #
		    $group = [ [ [ [ $symboli_group ] ], { action => $ACTION_FIRST_ARG } ] ];
		}
	    }
	    foreach (@{$group}) {
		my ($rhsp, $hintsp) = @{$_};
		my @rhs = defined($rhsp) ? (@{$rhsp} ? map {$_->[0]} @{$rhsp} : ()) : ();
		if ($#groups == 0) {
		    #
		    ## In reality, no '||', this is a normal concatenation. The auto-rank is done here...
		    #
		    if ($self->auto_rank) {
			$hintsp->{rank} = $rank--;
		    }
		    $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, {lhs => $symbol, rhs => [ @rhs ], %{$hintsp}});
		} else {
		    $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $actionsp, $nb_action_generatedp, {lhs => $symboli, rhs => [ @rhs ], %{$hintsp}});
		}
	    }
	    ++$i;
	}
    }
    #
    ## Finally, the result is always the same: $symbol
    #
    my $rc = $symbol;
    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# merge_hints
###############################################################################
sub merge_hints {
    my $self = shift;

    my $keysp = shift;
    my @keys = @{$keysp};
    my $rc = {};
    foreach (@_) {
	my $hint = $_;
	foreach (@keys) {
	    if (exists($hint->{$_})) {
		if (exists($rc->{$_})) {
		    croak "$_ is defined twice: $rc->{$_}, $hint->{$_}\n";
		}
		$rc->{$_} = $hint->{$_};
	    }
	}
    }

    return $rc;
}

###############################################################################
# validate_quantifier_maybe_and_hint
###############################################################################
sub validate_quantifier_maybe_and_hint {
    my ($self, $closure, $quantifier_maybe, $hint_quantifier_any) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_rule';

    $self->dumparg_in($closure, $quantifier_maybe, $hint_quantifier_any);

    my $rc = $hint_quantifier_any || {};
    $rc->{orig_quantifier_maybe} = '';
    if (defined($quantifier_maybe)) {
	$rc->{orig_quantifier_maybe} = $quantifier_maybe;
	if ($quantifier_maybe ne '') {
	    if (exists($hint_quantifier_any->{min})) {
		croak "Giving quantifier $quantifier_maybe and min => $hint_quantifier_any->{min} is not allowed\n";
	    }
	    #
	    ## Change '*' to min => 0
	    ## Change '?' to min => -1
	    ## Change '+' to min => 1
	    #
	    if ($self->is_star_quantifier($closure, $quantifier_maybe)) {
		$rc->{min} = 0;
	    } elsif ($self->is_questionmark_quantifier($closure, $quantifier_maybe)) {
		$rc->{min} = -1;
	    } elsif ($self->is_plus_quantifier($closure, $quantifier_maybe)) {
		$rc->{min} = 1;
	    } else {
		if (! ($quantifier_maybe =~ $TOKENS{DIGITS}->{re})) {
		    croak "Not a digit number: $quantifier_maybe\n";
		}
		$rc->{min} = int($quantifier_maybe);
	    }
	}
    }

    $self->dumparg_out($closure, $rc);

    return $rc;
}

###############################################################################
# grammar
###############################################################################
sub grammar {
    my ($self, $string, $optp) = @_;

    $self->manage_options(0, $optp);

    my %g0rules = ();
    my $g0 = 0;
    my %lhs = ();
    my %rhs = ();
    my %tokens = ();
    my %rules = ();
    my %actions = ();
    my @allrules = ();
    my $discard_rule = undef;
    my $nb_lhs_generated = 0;
    my $nb_token_generated = 0;
    my $nb_action_generated = 0;
    my $auto_rank = $self->auto_rank;

    my $hashp = MarpaX::Import::Grammar->new({grammarp => $GRAMMAR, tokensp => \%TOKENS});

    #
    ## We rely on high_rule_only to resolve some ambiguity and do not want user to change that
    ## We want the default action to be $ACTION_ARGS in this stage
    ## Our grammar should have no ambiguity
    #
    my $multiple_parse_values = $self->multiple_parse_values;
    $self->multiple_parse_values(0);
    my $default_action = $self->default_action;
    $self->default_action($ACTION_ARGS);
    my $ranking_method = $self->ranking_method;
    $self->ranking_method('high_rule_only');

    #
    ## In this array, we will put all strings that are not an lhs: then these are terminals
    #
    my %potential_token = ();

    #
    ## All actions have in common these arguments
    #
    my @COMMON_ARGS = (\%rules, \$nb_lhs_generated, \%tokens, \$nb_token_generated, \%actions, \$nb_action_generated);

    #
    ## We want persistency between startrule concerning the scratchpad, so we use our own
    #
    my %scratchpad = ();

    #
    ## In case of mutiple parse tree values, we maintain a value array, that will be used to
    ## differentiate the multiple trees in the dump.
    ## For efficiency reason, the dump is available only if $DEBUG_PROXY_ACTIONS == 1
    #
    my @value = ();
    #
    #
    ## We prepare internal hashes to ease the dump in case of
    ## detection of multiple parse trees
    #
    $self->{generated_token} = {};
    $self->{generated_lhs} = {};
    $self->{proxy} = {};

    #
    ## Lexer hints. They are always at the rule level.
    #
    my %lexhints = ();
    $self->recognize($hashp,
		     $string,
		     {
			 _action_symbol => sub {
			     shift;
			     return shift;
			 },
			 _action_word => sub {
			     shift;
			     #
			     ## Formally exactly the same code as _action_symbol_balanced
			     ## except with ++$potential_token{$rc}
			     #
			     my $closure = '_action_word';
			     my $rc = shift;
			     ++$potential_token{$rc};
			     return $self->make_symbol($closure, $rc);
			 },
			 _action_symbol_balanced => sub {
			     shift;
			     my $closure = '_action_symbol_balanced';
			     my $rc = shift;
			     substr($rc, $[, 1, '');
			     substr($rc, BEGSTRINGPOSMINUSONE, 1) = '';
			     #
			     ## In a balanced symbol, we remove surrounding spaces, and remove every
			     ## redundant space in between (space means \s)
			     #
			     $rc =~ s/^\s*//;
			     $rc =~ s/\s*$//;
			     $rc =~ s/\s+/ /;
			     return $self->make_symbol($closure, $rc);
			 },
			 _action_symbol__start => sub {
			     shift;
			     #
			     ## Formally exactly the same code as _action_symbol_balanced
			     ## except special eventual treatment since these are reserved symbols
			     ## In fact we do nothing special -;
			     #
			     my $closure = '_action_symbol__start';
			     my $rc = shift;
			     return $self->make_symbol($closure, $rc);
			 },
			_action_factor_lbracket_lcurly_expression_rcurly_plus_rbracket => sub {
			     shift;
			     my $closure = '_action_factor_lbracket_lcurly_expression_rcurly_plus_rbracket';
			     my (undef, undef, $expressionp, undef, undef, undef, $hintsp) = @_;
			     #
			     ## We make a rule out of this expression
			     #
			     my $lhs = $self->make_rule($closure, @COMMON_ARGS, undef, $expressionp);
			     #
			     ## And we quantify it
			     #
			     return $self->make_factor_quantifier_maybe($closure, @COMMON_ARGS, undef, $lhs, {min => 0});
			 },
			 _action_factor_lbracket_symbol_plus_rbracket => sub {
			     shift;
			     my $closure = '_action_factor_lbracket_symbol_plus_rbracket';
			     my (undef, $symbol, undef, undef, $hintsp) = @_;
			     return $self->make_factor_quantifier_maybe($closure, @COMMON_ARGS, "[$symbol+]", $symbol, {min => 0});
			 },
			 _action_factor_digits_star_lbracket_symbol_rbracket => sub {
			     shift;
			     my $closure = '_action_factor_digits_star_lbracket_symbol_rbracket';
			     my ($digits, undef, undef, $symbol, undef) = @_;
			     return $self->make_factor_quantifier_maybe($closure, @COMMON_ARGS, "$digits*[$symbol]", $symbol, {min => -1});
			 },
			 _action_factor_digits_star_lcurly_symbol_rcurly => sub {
			     shift;
			     my $closure = '_action_factor_digits_star_lcurly_symbol_rcurly';
			     my ($digits, undef, undef, $symbol, undef) = @_;
			     return $self->make_factor_quantifier_maybe($closure, @COMMON_ARGS, "$digits*{$symbol}", $symbol, $self->validate_quantifier_maybe_and_hint($closure, $digits, undef));
			 },
			 _action_factor_symbol_balanced_quantifier_maybe => sub {
			     shift;
			     my $closure = '_action_factor_symbol_balanced_quantifier_maybe';
			     my ($symbol, $quantifier_maybe, $hint_quantifier_any) = @_;
			     return $self->make_factor_symbol_quantifier_maybe($closure, @COMMON_ARGS, $symbol, $self->validate_quantifier_maybe_and_hint($closure, $quantifier_maybe, $hint_quantifier_any));
			 },
			 _action_factor_word_quantifier_maybe => sub {
			     shift;
			     #
			     ## Formally exactly the same code as _action_factor_symbol_balanced_quantifier_maybe
			     ## except with ++$potential_token{$word}
			     #
			     my $closure = '_action_factor_word_quantifier_maybe';
			     my ($word, $quantifier_maybe, $hint_quantifier_any) = @_;
			     ++$potential_token{$word};
			     return $self->make_factor_symbol_quantifier_maybe($closure, @COMMON_ARGS, $word, $self->validate_quantifier_maybe_and_hint($closure, $quantifier_maybe, $hint_quantifier_any));
			 },
			 _action_factor_digits_star_symbol_balanced => sub {
			     shift;
			     my $closure = '_action_factor_digits_star_symbol_balanced';
			     my ($digits, $star, $symbol, $hint_quantifier_any) = @_;
			     return $self->make_factor_symbol_quantifier_maybe($closure, @COMMON_ARGS, $symbol, $self->validate_quantifier_maybe_and_hint($closure, $digits, $hint_quantifier_any));
			 },
			 _action_factor_digits_star_word => sub {
			     shift;
			     #
			     ## Formally exactly the same code as _action_factor_digits_star_symbol_balanced
			     ## except with ++$potential_token{$word}
			     #
			     my $closure = '_action_factor_digits_star_word';
			     my ($digits, $star, $word, $hint_quantifier_any) = @_;
			     ++$potential_token{$word};
			     return $self->make_factor_symbol_quantifier_maybe($closure, @COMMON_ARGS, $word, $digits, $hint_quantifier_any || {});
			 },
			 _action_factor_expression_maybe => sub {
			     shift;
			     my $closure = '_action_factor_expression_maybe';
			     my (undef, $expressionp, undef) = @_;
			     return $self->make_factor_expression_quantifier_maybe($closure, @COMMON_ARGS, $expressionp, $self->validate_quantifier_maybe_and_hint($closure, '?', undef));
			 },
			 _action_factor_digits_star_expression => sub {
			     shift;
			     my $closure = '_action_factor_digits_star_expression';
			     my ($digits, $star, $expressionp) = @_;
			     return $self->make_factor_expression_quantifier_maybe($closure, @COMMON_ARGS, $expressionp, $self->validate_quantifier_maybe_and_hint($closure, $digits, undef));
			 },
			 _action_factor_expression_quantifier_maybe => sub {
			     shift;
			     my $closure = '_action_factor_expression_quantifier_maybe';
			     my (undef, $expressionp, undef, $quantifier_maybe, $hint_quantifier_any) = @_;
			     return $self->make_factor_expression_quantifier_maybe($closure, @COMMON_ARGS, $expressionp, $self->validate_quantifier_maybe_and_hint($closure, $quantifier_maybe, $hint_quantifier_any));
			 },
			 _action_factor_string_quantifier_maybe => sub {
			     shift;
			     my $closure = '_action_factor_string_quantifier_maybe';
			     my ($string, $quantifier_maybe, $hint_quantifier_any) = @_;
			     return $self->make_factor_string_quantifier_maybe($closure, @COMMON_ARGS, $string, $self->validate_quantifier_maybe_and_hint($closure, $quantifier_maybe, $hint_quantifier_any));
			 },
			 _action_factor_digits_star_string => sub {
			     shift;
			     my $closure = '_action_factor_digits_star_string';
			     my ($digits, $star, $string) = @_;
			     return $self->make_factor_string_quantifier_maybe($closure, @COMMON_ARGS, $string, $self->validate_quantifier_maybe_and_hint($closure, $digits, undef));
			 },
			 _action_factor_regexp => sub {
			     shift;
			     my $closure = '_action_factor_regexp';
			     my ($string) = @_;
			     my $regexp = $string;
			     substr($regexp, $[, 3) = '';
			     substr($regexp, BEGSTRINGPOSMINUSONE, 1) = '';
			     if ($self->regexp_common) {
				 $regexp = $self->handle_regexp_common($closure, $regexp);
			     }
			     my $re = qr/\G(?:$regexp)/ms;
			     return $self->make_re($closure, @COMMON_ARGS, undef, $string, $re);
			 },
			 _action_factor_char_range_quantifier_maybe => sub {
			     shift;
			     my $closure = '_action_factor_char_range_quantifier_maybe';
			     my ($char_range, $quantifier_maybe, $hint_quantifier_any) = @_;
			     return $self->make_factor_char_range_quantifier_maybe($closure, @COMMON_ARGS, $char_range, 'CHAR_RANGE', $self->validate_quantifier_maybe_and_hint($closure, $quantifier_maybe, $hint_quantifier_any));
			 },
			 _action_factor_digits_star_char_range => sub {
			     shift;
			     my $closure = '_action_factor_digits_star_char_range';
			     my ($digits, $char_range) = @_;
			     return $self->make_factor_char_range_quantifier_maybe($closure, @COMMON_ARGS, $char_range, 'CHAR_RANGE', $self->validate_quantifier_maybe_and_hint($closure, $digits, undef));
			 },
			 _action_factor_caret_char_range_quantifier_maybe => sub {
			     shift;
			     my $closure = '_action_factor_caret_char_range_quantifier_maybe';
			     my ($caret_char_range, $quantifier_maybe, $hint_quantifier_any) = @_;
			     return $self->make_factor_char_range_quantifier_maybe($closure, @COMMON_ARGS, $caret_char_range, 'CARET_CHAR_RANGE', $self->validate_quantifier_maybe_and_hint($closure, $quantifier_maybe, $hint_quantifier_any));
			 },
			 _action_factor_digits_star_caret_char_range => sub {
			     shift;
			     my $closure = '_action_factor_digits_star_caret_char_range';
			     my ($caret_char_range, $quantifier_maybe, $hint_quantifier_any) = @_;
			     return $self->make_factor_char_range_quantifier_maybe($closure, @COMMON_ARGS, $caret_char_range, 'CARET_CHAR_RANGE', $self->validate_quantifier_maybe_and_hint($closure, $quantifier_maybe, $hint_quantifier_any));
			 },
			 _action_factor_hexchar_many_quantifier_maybe => sub {
			     shift;
			     my $closure = '_action_factor_hexchar_many_quantifier_maybe';
			     my ($hexchar_many, $quantifier_maybe, $hint_quantifier_any) = @_;
			     return $self->make_factor_quantifier_maybe($closure, @COMMON_ARGS, undef, $hexchar_many, $self->validate_quantifier_maybe_and_hint($closure, $quantifier_maybe, $hint_quantifier_any));
			 },
			 _action_hexchar_many => sub {
			     shift;
			     my $closure = '_action_hexchar_many';
			     my (@hexchar) = @_;
			     return $self->make_concat($closure, @COMMON_ARGS,
						       undef,
						       map
						       {
							   my $orig = $_;
							   $orig =~ $TOKENS{HEXCHAR}->{re};
							   my $r = '\\x{' . substr($orig, $-[2], $+[2] - $-[2]) . '}';
							   my $re = qr/\G(?:$r)/ms;
							   $self->make_re($closure, @COMMON_ARGS, undef, $orig, $re);
						       } @hexchar);
			 },
			 _action_quantifier => sub {
			     shift;
			     my $closure = '_action_quantifier';
			     my ($quantifier) = @_;
			     return $quantifier;
			 },
			 _action_quantifier_maybe => sub {
			     shift;
			     my $closure = '_action_quantifier_maybe';
			     my ($quantifier) = @_;
			     return $quantifier;
			 },
			 _action_comma_maybe => sub {
			     shift;
			     my $closure = '_action_comma_maybe';
			     my ($comma) = @_;
			     return $comma;
			 },
			 _action_term => sub {
			     shift;
			     my $closure = '_action_term';
			     my ($factor) = @_;
			     return $factor;
			 },
			 _action_more_term_maybe => sub {
			     shift;
			     my $closure = '_action_more_term_maybe';
			     my ($more_term) = @_;
			     return $more_term;
			 },
			 _action_more_term => sub {
			     shift;
			     my $closure = '_action_more_term';
			     my (undef, $term) = @_;
			     return $term;
			 },
			 _action_exception => sub {
			     shift;
			     my $closure = '_action_exception';
			     my $comma_maybe = pop(@_);
			     my $rc = [ grep {defined($_)} @_ ];
			     if ($#{$rc} > 0) {
				 my ($term1, $term2) = @{$rc};
				 my $orig = "$term1 - $term2";
				 #
				 ## An exception is: term1 - term2.
				 ## We fake the fact the we only want term1 by creating
				 ## a rule like ( term2 | term1 )
				 ## In case term2 is used elsewhere, as well as term1, we create
				 ## explicitely two new redundant lhs that are:
				 ## lsh2 => term2       action: failure
				 ## lsh1 => term1
				 ## and finally use (lhs2 || lhs1) in the grammar
				 ## This mean that our internal recognizer will have to provide an internal action
				 ## for the failure. In the exceptional case where our caller would
				 ## already own an action with the same name, this is configurable
				 ## via $self->action_failure
				 #
				 # my $lhs1 = $self->add_rule($closure, @COMMON_ARGS, {rhs => [ $term1 ]});
				 # my $lhs2 = $self->add_rule($closure, @COMMON_ARGS, {action => $self->action_failure, rhs => [ $term2 ]});
				 # my $lhs = $self->make_any($closure, @COMMON_ARGS, undef, undef, $lhs2, $lhs1);
                                 my $lhs = $self->make_rule($closure, @COMMON_ARGS, undef,
                                                            [
                                                             [ undef,  [ [ $term2 ] ], { rank => 1, action => $self->action_failure } ],
                                                             [
                                                              [ '|',   [ [ $term1 ] ], { rank => 0, action => $ACTION_FIRST_ARG } ],
                                                             ]
                                                            ]
                                                           );

				 $rc = [ $lhs ];
			     }
			     return $rc;
			 },
			 _action_exception_any => sub {
			     shift;
			     my $closure = '_action_exception_any';
			     return [ @_ ];
			 },
			 _action_exception_many => sub {
			     shift;
			     my $closure = '_action_exception_many';
			     return [ @_ ];
			 },
			 _action_hint_star => sub {
			     shift;
			     my $closure = '_action_hint_star';
			     return {min => 0};
			 },
			 _action_hint_plus => sub {
			     shift;
			     my $closure = '_action_hint_plus';
			     return {min => 1};
			 },
			 _action_hint_questionmark => sub {
			     shift;
			     my $closure = '_action_hint_questionmark';
			     # Take care, we use the forbidden min value of -1 to say: ?
			     return {min => -1};
			 },
			 _action_hint_rank => sub {
			     shift;
			     my $closure = '_action_hint_rank';
			     my (undef, undef, $rank) = @_;
			     if (defined($rank) && $auto_rank) {
				 croak "rank => $rank is incompatible with option auto_rank\n";
			     }
			     return {rank => $rank};
			 },
			 _action_hint_action => sub {
			     shift;
			     my $closure = '_action_hint_action';
			     my (undef, undef, $action) = @_;
			     return {action => $action};
			 },
			 _action_hint_bless => sub {
			     shift;
			     my $closure = '_action_bless_action';
			     my (undef, undef, $bless) = @_;
			     return {bless => $bless};
			 },
			 _action_hint_quantifier_separator => sub {
			     shift;
			     my $closure = '_action_hint_quantifier_separator';
			     my (undef, undef, $separator) = @_;
			     return {separator => $separator};
			 },
			 _action_hint_quantifier_proper => sub {
			     shift;
			     my $closure = '_action_hint_quantifier_proper';
			     my (undef, undef, $proper) = @_;
			     return {proper => $proper};
			 },
			 _action_hint_assoc => sub {
			     shift;
			     my $closure = '_action_hint_assoc';
			     my (undef, undef, $assoc) = @_;
			     return {assoc => $assoc};
			 },
			 _action_lexhint_pre => sub {
			     shift;
			     my $closure = '_action_lexhint_pre';
			     my (undef, undef, $pre) = @_;
			     return {pre => $pre};
			 },
			 _action_lexhint_post => sub {
			     shift;
			     my $closure = '_action_lexhint_post';
			     my (undef, undef, $post) = @_;
			     return {post => $post};
			 },
			 #
			 ## This rule merges all hints into a single return value
			 #
			 _action_hint_any => sub {
			     shift;
			     my $closure = '_action_hint_any';
			     my (@hints) = @_;
			     return $self->merge_hints([qw/action bless assoc rank/], @hints);
			 },
			 _action_lexhint_any => sub {
			     shift;
			     my $closure = '_action_lexhint_any';
			     my (@lexhints) = @_;
			     return $self->merge_hints([qw/pre post/], @lexhints);
			 },
			 #
			 ## This rule merges all quantifier hints into a single return value
			 #
			 _action_hint_quantifier_any => sub {
			     shift;
			     my $closure = '_action_hint_quantifier_any';
			     my (@hints) = @_;
			     return $self->merge_hints([qw/separator proper/], @hints);
			 },
			 _action_hints_maybe => sub {
			     shift;
			     my $closure = '_action_hints_maybe';
			     my ($hint) = @_;
			     return $hint;
			 },
			 _action_lexhints_maybe => sub {
			     shift;
			     my $closure = '_action_lexhints_maybe';
			     my ($lexhint) = @_;
			     return $lexhint;
			 },
			 _action_comment => sub {
			     return undef;
			 },
			 _action_ignore => sub {
			     return undef;
			 },
			 _action_concatenation => sub {
			     shift;
			     my $closure = '_action_concatenation';
			     my ($exception_any, $hints_maybe) = @_;
			     #
			     ## The very first concatenation is marked with undef instead of PIPE
			     #
			     return [ undef, $exception_any, $hints_maybe || {} ];
			 },
			 _action_concatenation_hints_maybe => sub {
			     shift;
			     my $closure = '_action_concatenation_hint_maybe';
			     my ($hints_maybe, $dumb_any) = @_;
			     #
			     ## The very first concatenation is marked with undef instead of PIPE
			     #
			     return [ undef, [], $hints_maybe || {} ];
			 },
			 _action_more_concatenation_any => sub {
			     shift;
			     my $closure = '_action_more_concatenation_any';
			     return [ @_ ];
			 },
			 _action_more_concatenation => sub {
			     shift;
			     my $closure = '_action_more_concatenation';
			     my ($pipe, $concatenation) = @_;
			     if (! defined($concatenation)) {
				 #
				 ## Nullable
				 #
				 $concatenation = [ undef, [], {} ];
			     }
			     #
			     ## We put the PIPE information
			     #
			     $concatenation->[0] = $pipe;
			     return $concatenation;
			 },
			 _action_expression => sub {
			     shift;
			     my $closure = '_action_expression';
			     return [ @_ ];
			 },
			 _action__realstart => sub {
			     return undef;
			 },
			 _action_rule => sub {
			     shift;
			     my $closure = '_action_rule';
			     my ($symbol, $lexhintsp, $rulesep, $expressionp);
			     if (scalar(@_) == 5) {
				 (       $symbol, $lexhintsp, $rulesep, $expressionp, undef) = @_;
			     } else {
				 (undef, $symbol, $lexhintsp, $rulesep, $expressionp, undef) = @_;
			     }
			     my $rc;
			     if ($rulesep eq '~') {
				 #
				 ## The whole grammar is turned into a 'what I say' mode
				 #
				 $g0rules{$symbol} = 1;
				 #
				 ## This a G0 rule
				 #
				 if ($symbol eq ':discard') {
				     #
				     ## This is the :discard special rule - remember we got it
				     #
				     $discard_rule = $symbol;
				     #
				     ## In reality $expressionp is a symbol. Our grammar made sure there is no action.
				     #
				     $rc = $self->add_rule($closure, @COMMON_ARGS, {lhs => $symbol, rhs => [ $expressionp ], action => $ACTION_WHATEVER});
				 } else {
				     #
				     ## This is a normal expression
				     #
				     $rc = $rc = $self->make_rule($closure, @COMMON_ARGS, $symbol, $expressionp);
				 }
			     } else {
				 #
				 ## This is a normal expression
				 #
				 $rc = $self->make_rule($closure, @COMMON_ARGS, $symbol, $expressionp);
			     }
			     if (defined($rc)) {
				 push(@allrules, $rc);
			     }
                             #
                             ## Save lexer hints
                             #
                             $lexhints{$rc} = $lexhintsp;

			     return $rc;
			 },
			 _action_ruleend_maybe => sub {
			     return undef;
			 },
		     }
	)
	||
	croak "Recognizer error";

    #
    ## Is this a G0 aware grammar ?
    #
    $g0 = (%g0rules || exists($rules{':discard'})) ? 1 : 0;
    #
    ## We create all terminals that were not done automatically because the writer decided
    ## to write symbols not using <symbol> notation
    #
    foreach (keys %potential_token) {
	my $token = $_;
	#
	## If this is known LHS, ok, no need to create it
	#
	if (exists($rules{$token})) {
	    next;
	}
	#
	## This really is a terminal, we create the corresponding token - that is a single string
	#
	$self->make_token_if_not_exist('grammar', \%tokens, \$nb_token_generated, $token, $token, $token, undef);
    }

    #
    ## startrules option is not valid if there is already a :start one, unless startrules contains exactly :start
    #
    if (@{$self->startrules} && exists($rules{':start'}) && (($#{$self->startrules} > 0) || ($self->startrules->[0] ne ':start'))) {
	croak "startrules must contain only :start because there is a :start LHS in your grammar\n";
    }
    #
    ## discardrules option is not valid if there is already a :discard one, unless discardrules contains exactly :discard
    #
    if (@{$self->discardrules} && exists($rules{':discard'}) && (($#{$self->discardrules} > 0) || ($self->discardrules->[0] ne ':discard'))) {
	croak "discardrules must contain only :discard because there is a :discard LHS in your grammar\n";
    }
    #
    ## We expect the user to give a startrule containing only rules that belong to the grammar
    #
    my $startok = 0;
    foreach (@{$self->startrules}) {
	my $this = $_;
	if (! grep {$this eq $_} @allrules) {
	    croak "Start rule $this is not a rule in your grammar\n";
	} else {
	    ++$startok;
	}
    }
    if ($startok == 0) {
	croak "Please give at least one startrule\n";
    }

    #
    ## Unless startrule consist of a single rule, we concatenate
    ## what was given
    #
    my $start;
    if ($#{$self->startrules} > 0) {
	$start = $self->make_any(undef, @COMMON_ARGS, @{$self->startrules});
    } else {
	$start = $self->startrules->[0];
    }

    #
    ## If there is no g0 rule, then there is no :discard rule.
    ## In such a case we insert ourself a :discard that consist of [\s]
    #
    if (! $g0) {
	if ($DEBUG_PROXY_ACTIONS) {
	    $log->debugf('No G0 rule, creating a fake :discard consisting of characters \\f, \\r, \\n, \\t and \' \'');
	}
	my $f = $self->make_token_if_not_exist('grammar', \%tokens, \$nb_token_generated, undef, "\f", "\f", undef);
	my $r = $self->make_token_if_not_exist('grammar', \%tokens, \$nb_token_generated, undef, "\r", "\r", undef);
	my $n = $self->make_token_if_not_exist('grammar', \%tokens, \$nb_token_generated, undef, "\n", "\n", undef);
	my $t = $self->make_token_if_not_exist('grammar', \%tokens, \$nb_token_generated, undef, "\t", "\t", undef);
	my $s = $self->make_token_if_not_exist('grammar', \%tokens, \$nb_token_generated, undef, ' ', ' ', undef);
	$discard_rule = $self->add_rule('grammar', @COMMON_ARGS, {lhs => ':discard', rhs => [ $f ], action => $ACTION_WHATEVER});
	$discard_rule = $self->add_rule('grammar', @COMMON_ARGS, {lhs => ':discard', rhs => [ $r ], action => $ACTION_WHATEVER});
	$discard_rule = $self->add_rule('grammar', @COMMON_ARGS, {lhs => ':discard', rhs => [ $n ], action => $ACTION_WHATEVER});
	$discard_rule = $self->add_rule('grammar', @COMMON_ARGS, {lhs => ':discard', rhs => [ $t ], action => $ACTION_WHATEVER});
	$discard_rule = $self->add_rule('grammar', @COMMON_ARGS, {lhs => ':discard', rhs => [ $s ], action => $ACTION_WHATEVER});
    }

    #
    ## If there is a :discard rule
    ## We create a :discard_any, no need to go through the add_rule complicated stuff about min => 0
    ## For every token used only in G1 (rule level) we create a rule xtoken => token :discard_any, with action $ACTION_FIRST_ARG
    ## For every symbol used in G1 (rule level) and that is a rule in G0 we create a rule xsymbol => symbol :discard_any, with action $ACTION_FIRST_ARG, except for :discard itself
    ## We add a new start rule $start -> :discard_any realstart, in order to eliminate eventual first discarded tokens
    #
    if (defined($discard_rule)) {
	if ($DEBUG_PROXY_ACTIONS) {
	    $log->debugf(':discard exist, post-processing the default grammar');
	}
	my $discard_any = $self->add_rule('grammar', @COMMON_ARGS, {rhs => [ $discard_rule ], action => $ACTION_WHATEVER});
	$start = $self->add_rule('grammar', @COMMON_ARGS, {rhs => [ $discard_any, $start ], action => $ACTION_SECOND_ARG});

        my %g1tokens = ();
        my %g1symbol2g0rules = ();
	foreach (keys %rules) {
            if (exists($g0rules{$_})) {
              next;
            }
	    foreach (@{$rules{$_}}) {
              foreach (@{$_->{rhs}}) {
                if (exists($tokens{$_})) {
                  $g1tokens{$_} = 1;
                } elsif (($_ ne $discard_rule) && exists($g0rules{$_})) {
		    $g1symbol2g0rules{$_} = 1;
		}
              }
            }
        }

	my %rhs2lhs = ();
	my %generated = ();
	foreach (keys %g1tokens, keys %g1symbol2g0rules) {
	    $rhs2lhs{$_} = $self->add_rule('grammar', @COMMON_ARGS, {rhs => [ $_, $discard_any ], action => $ACTION_FIRST_ARG});
	    $generated{$rhs2lhs{$_}} = 1;
	}
	foreach (keys %rules) {
	    if (exists($generated{$_})) {
		next;
	    }
	    foreach (@{$rules{$_}}) {
		if ($_->{lhs} eq $discard_any) {
		    $_->{min} = 0;
		}
		my @newrhs = ();
		foreach (@{$_->{rhs}}) {
		    if (exists($rhs2lhs{$_})) {
			push(@newrhs, $rhs2lhs{$_});
		    } else {
			push(@newrhs, $_);
		    }
		}
		$_->{rhs} = [ @newrhs ];
	    }
	}
    }

    #
    ## Restore things that we eventually overwrote
    #
    $self->multiple_parse_values($multiple_parse_values);
    $self->default_action($default_action);
    $self->ranking_method($ranking_method);

    if ($DEBUG_PROXY_ACTIONS) {
	$log->debugf('Default action        => %s', $self->default_action);
	$log->debugf('Action object         => %s', $self->action_object);
	$log->debugf('Bless package         => %s', $self->bless_package);
	$log->debugf('Infinite action       => %s', $self->infinite_action);
	$log->debugf('Multiple parse values => %d', $self->multiple_parse_values);
	$log->debugf('Marpa compatilibity   => %d', $self->marpa_compat);
	$log->debugf('Start rule            => %s', $start);
	$log->debugf('G0 mode               => %d', $g0);
    }

    my @rules = ();
    foreach (sort keys %rules) {
	foreach (@{$rules{$_}}) {
	    if ($DEBUG_PROXY_ACTIONS) {
		$log->debugf('Grammar rule: {lhs => \'%s\', rhs => [\'%s\'], min => %s, action => %s, rank => %s, separator => %s, proper => %s',
                             $_->{lhs},
                             join('\', \'', @{$_->{rhs}}),
                             exists($_->{min})       && defined($_->{min})       ? $_->{min}                     : '<none>',
                             exists($_->{action})    && defined($_->{action})    ? $_->{action}                  : '<none>',
                             exists($_->{rank})      && defined($_->{rank})      ? $_->{rank}                    : '<none>',
                             exists($_->{separator}) && defined($_->{separator}) ? '\'' . $_->{separator} . '\'' : '<none>',
                             exists($_->{proper})    && defined($_->{proper})    ? $_->{proper}                  : '<none>');
	    }
	    push(@rules, $_);
	}
    }

    if ($DEBUG_PROXY_ACTIONS) {
	foreach (sort keys %tokens) {
	    $log->debugf('Token %s: orig=%s, re=%s, string=%s, code=%s',
			 $_,
			 (exists($tokens{$_}->{orig})   && defined($tokens{$_}->{orig})   ? $tokens{$_}->{orig}   : ''),
			 (exists($tokens{$_}->{re})     && defined($tokens{$_}->{re})     ? $tokens{$_}->{re}     : ''),
			 (exists($tokens{$_}->{string}) && defined($tokens{$_}->{string}) ? $tokens{$_}->{string} : ''),
			 (exists($tokens{$_}->{code})   && defined($tokens{$_}->{code})   ? $tokens{$_}->{code}   : ''));
	}
    }

    #
    ## Generate the grammar from input string and return a MarpaX::Import::Grammar object
    #
    my %grammar = (
	start                => $start,
	default_action       => $self->default_action,
	action_object        => $self->action_object,
	bless_package        => $self->bless_package,
	infinite_action      => $self->infinite_action,
	trace_file_handle    => $MARPA_TRACE_FILE_HANDLE,
	terminals            => [keys %tokens],
	rules                => \@rules
	);
    my $grammar = Marpa::R2::Grammar->new(\%grammar);
    $grammar->precompute();

    my $rc = MarpaX::Import::Grammar->new({grammarp => $grammar, rulesp => \@rules, tokensp => \%tokens, g0rulesp => \%g0rules, lexhintsp => \%lexhints, actionsp => \%actions});

    return $rc;
}

###############################################################################
# lexer
# In this routine, we do a special effort to not alter @_ content
###############################################################################
sub lexer {
    # $self = $_[0]
    # $string = $_[1]
    # $line = $_[2]
    # $tokensp = $_[3]
    # $pos = $_[4]
    # $posline = $_[5]
    # $linenb = $_[6]
    # $expected = $_[7]
    # $matchesp = $_[8]
    # $longest_match = $_[9]

    my $maxlen = 0;

    foreach (@{$_[7]}) {
	# $token_name = $_;
	# my $pre  = $_[3]->{$_}->{pre};
	# my $post = $_[3]->{$_}->{post};
	# my $code = $_[3]->{$_}->{code};
	if (exists($_[3]->{$_}->{pre})) {
	    if (! $_[3]->{$_}->{pre}(@_, $_)) {
		next;
	    }
	}
	my $rc = undef;
	if (! $_[3]->{$_}->{code}(@_, $_, \$rc)) {
	    next;
	}
	if (exists($_[3]->{$_}->{post})) {
	    if (! $_[3]->{$_}->{post}(@_, $_, $rc)) {
		next;
	    }
	}
	if ($_[9]) {
	    #
	    ## Keep only the longest tokens
	    #
	    if ($rc->[2] > $maxlen) {
		@{$_[8]} = ();
		$maxlen = $rc->[2];
		push(@{$_[8]}, $rc);
	    } elsif ($rc->[2] == $maxlen) {
		push(@{$_[8]}, $rc);
	    }
	} else {
	    push(@{$_[8]}, $rc);
	}
    }
};

###############################################################################
# trace_terminals
###############################################################################
sub trace_terminals {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('trace_terminals', '', @_);
	$self->{trace_terminals} = shift;
    }
    return $self->{trace_terminals};
}

###############################################################################
# style
###############################################################################
sub style {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('style', '', @_);
	$self->{style} = shift;
    }
    return $self->{style};
}

###############################################################################
# trace_values
###############################################################################
sub trace_values {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('trace_values', '', @_);
	$self->{trace_values} = shift;
    }
    return $self->{trace_values};
}

###############################################################################
# trace_actions
###############################################################################
sub trace_actions {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('trace_actions', '', @_);
	$self->{trace_actions} = shift;
    }
    return $self->{trace_actions};
}

###############################################################################
# auto_rank
###############################################################################
sub auto_rank {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('auto_rank', '', @_);
	$self->{auto_rank} = shift;
    }
    return $self->{auto_rank};
}

###############################################################################
# multiple_parse_values
###############################################################################
sub multiple_parse_values {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('multiple_parse_values', '', @_);
	$self->{multiple_parse_values} = shift;
    }
    return $self->{multiple_parse_values};
}

###############################################################################
# longest_match
###############################################################################
sub longest_match {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('longest_match', '', @_);
	$self->{longest_match} = shift;
    }
    return $self->{longest_match};
}

###############################################################################
# marpa_compat
###############################################################################
sub marpa_compat {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('marpa_compat', '', @_);
	$self->{marpa_compat} = shift;
    }
    return $self->{marpa_compat};
}

###############################################################################
# generated_lhs_format
###############################################################################
sub generated_lhs_format {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('generated_lhs_format', '', @_);
	$self->{generated_lhs_format} = shift;
    }
    return $self->{generated_lhs_format};
}


###############################################################################
# generated_action_format
###############################################################################
sub generated_action_format {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('generated_action_format', '', @_);
	$self->{generated_action_format} = shift;
    }
    return $self->{generated_action_format};
}


###############################################################################
# generated_token_format
###############################################################################
sub generated_token_format {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('generated_token_format', '', @_);
	$self->{generated_token_format} = shift;
    }
    return $self->{generated_token_format};
}

###############################################################################
# position_trace
###############################################################################
sub position_trace {
    my ($self, $linenb, $colnb, $pos, $pos_max) = @_;
    my $rc = sprintf($self->position_trace_format, $linenb, $colnb, $pos, $pos_max);
    return $rc;
}

###############################################################################
# position_trace_format
###############################################################################
sub position_trace_format {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('position_trace_format', '', @_);
	$self->{position_trace_format} = shift;
    }
    return $self->{position_trace_format};
}



###############################################################################
# default_assoc
###############################################################################
sub default_assoc {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('default_assoc', '', @_);
	$self->{default_assoc} = shift;
    }
    return $self->{default_assoc};
}

###############################################################################
# startrules
###############################################################################
sub startrules {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('startrules', 'ARRAY', @_);
	$self->{startrules} = shift;
    }
    return $self->{startrules};
}

###############################################################################
# discardrules
###############################################################################
sub discardrules {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('discardrules', 'ARRAY', @_);
	$self->{discardrules} = shift;
    }
    return $self->{discardrules};
}

###############################################################################
# action_failure
###############################################################################
sub action_failure {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('action_failure', '', @_);
	$self->{action_failure} = shift;
    }
    return $self->{action_failure};
}

###############################################################################
# char_escape
###############################################################################
sub char_escape {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('char_escape', '', @_);
	$self->{char_escape} = shift;
    }
    return $self->{char_escape};
}

###############################################################################
# regexp_common
###############################################################################
sub regexp_common {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('regexp_common', '', @_);
	$self->{regexp_common} = shift;
    }
    return $self->{regexp_common};
}

###############################################################################
# char_class
###############################################################################
sub char_class {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('char_class', '', @_);
	$self->{char_class} = shift;
    }
    return $self->{char_class};
}

###############################################################################
# infinite_action
###############################################################################
sub infinite_action {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('infinite_action', '', @_);
	$self->{infinite_action} = shift;
    }
    return $self->{infinite_action};
}

###############################################################################
# default_action
###############################################################################
sub default_action {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('default_action', '', @_);
	$self->{default_action} = shift;
    }
    return $self->{default_action};
}

###############################################################################
# ranking_method
###############################################################################
sub ranking_method {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('ranking_method', '', @_);
	$self->{ranking_method} = shift;
    }
    return $self->{ranking_method};
}

###############################################################################
# action_object
###############################################################################
sub action_object {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('action_object', '', @_);
	$self->{action_object} = shift;
    }
    return $self->{action_object};
}

###############################################################################
# bless_package
###############################################################################
sub bless_package {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('bless_package', '', @_);
	$self->{bless_package} = shift;
    }
    return $self->{bless_package};
}

###############################################################################
# action_two_args_recursive
###############################################################################
sub action_two_args_recursive {
    my $scratchpad = shift;
    my $rc;
    if ($#_ == 0) {
	#
	## rule* :: rule
	#
	#
	## rule* ::= rule* rule
	## cannot be hitted before this one. So, IF, we are going
	## to hit the recursion, we mark right now a boolean
	## do distinguish the first hit from the others
	#
	$scratchpad->{action_two_args_recursive_count} = 1;
	$rc = [ $_[0]->[0] ];
    } else {
	if (! exists($scratchpad->{action_two_args_recursive_count})) {
	    #
	    ## This should never happen
	    #
	    my $rule_id = $Marpa::R2::Context::rule;
	    my $g = $Marpa::R2::Context::grammar;
	    my $what = '';
	    my $lhs = '';
	    my @rhs = ();
	    if (defined($rule_id) && defined($g)) {
		my ($lhs, @rhs) = $g->rule($rule_id);
		$what = sprintf(', %s ::= %s ', $lhs, join(' ', @rhs));
	    }
	    $log->tracef("Hit in recursive rule without a hit on the single item%s", $what);
	    $log->tracef("Values of the rhs: %s", \@_);
	    croak('Hit in recursive rule without a hit on the single item');
	}
	if ($scratchpad->{action_two_args_recursive_count} == 1) {
	    $rc = [ $_[0]->[0], $_[1]->[0] ];
	    ++$scratchpad->{action_two_args_recursive_count};
	} else {
	    $rc = [ @{$_[0]}, $_[1]->[0] ];
	}
    }

    return $rc;
}

###############################################################################
# action_make_arrayp
###############################################################################
sub action_make_arrayp {
    shift;

    #
    ## This rule is used INTERNALY and recursively in the generated
    ## lhs that is:
    ## rule*    ::= rule* rule
    ##           |  rule
    ## We want to mimic rule min => 0, that is: always return something in the
    ## form: [ [x1,x2,x3], [y1,y2,y3], [z1,z2,z3] ]
    ##
    ## But when rule is matched only ONCE, then we have in input only this:
    ## [x1,x2,x3]
    ## So we have to detect if the first is a reference or not. And if not this
    ## mean that rule was matches only once, and then we return [ [x1,x2,x3] ]
    #
    my $rc = [];
    if (@_) {
      if (! ref($_[0])) {
	$rc = [ @_ ];
      } else {
	$rc = $_[0];
      }
    }

    return $rc;
}

###############################################################################
# action_args
###############################################################################
sub action_args {
    shift;
    return [ @_ ];
}

###############################################################################
# action_first_arg
###############################################################################
sub action_first_arg {
  __PACKAGE__->_dumparg("==> action_first_arg", @_);
  __PACKAGE__->_dumparg("<== action_first_arg", $_[1]);

    return $_[1];
}

###############################################################################
# action_last_arg
###############################################################################
sub action_last_arg {
    return $_[-1];
}

###############################################################################
# action_odd_args
###############################################################################
sub action_odd_args {
    shift;

    my $i = 0;
    #
    ## We use $j instead of modulo for speed reasons
    #
    my $j = 0;
    my @rc = ();
    for ($i = 0, $j = 0; $i <= $#_; $i++) {
	if ($j++ == 0) {
	    push(@rc, $_[$i]);
	} else {
	    $j = 0;
	}
    }
    my $rc = [ @rc ];

    return $rc;

}

###############################################################################
# action_second_arg
###############################################################################
sub action_second_arg {
    return $_[2];
}

###############################################################################
# recognize
###############################################################################
sub recognize {
    my ($self, $hashp, $string, $closuresp) = @_;

    croak "No valid input hashp\n" if (! defined($hashp) || ref($hashp) ne 'MarpaX::Import::Grammar');
    croak "No valid input string\n" if (! defined($string) || ! "$string");

    my $grammarp = $hashp->grammarp;
    my $tokensp = $hashp->tokensp;
    my $lexhintsp = $hashp->lexhintsp;
    my $actionsp = $hashp->actionsp;

    my $pos_max = length($string) - 1;

    #
    ## We add to closures our internal action for exception handling, and the eventual generated actions
    #
    my $okclosuresp = $closuresp || {};
    foreach (keys %{$actionsp}) {
	$okclosuresp->{$_} = $actionsp->{$_}->{code};
    }
    #
    ## Handle the exceptions
    #
    local $__PACKAGE__::failure = 0;
    $okclosuresp->{$self->action_failure} = sub {
	shift;
        #
        # my ( $lhs, @rhs ) = $grammarp->rule($Marpa::R2::Context::rule);
        # $log->tracef("Exception in rule: %s ::= %s", $lhs, join(' ', @rhs));
        # $log->tracef("Values of the rhs: %s", \@_);
        # Marpa::R2::Context::bail('Exception');
	$__PACKAGE__::failure = 1;
    };

    # Cache some values
    my $is_debug = $log->is_debug;
    my $is_trace = $log->is_trace;

    #
    ## Comments are not part of the grammar
    ## We remove them, taking into account newlines
    ## The --hr, --li, --## have to be in THIS regexp because of the ^ anchor, that is not propagated
    ## if it would be in $WEBCODE_RE
    #
    # $string =~ s#^[^\n]*\-\-(?:hr|li|\#\#)[^\n]*|$WEBCODE_RE#my ($start, $end, $length) = ($-[0], $+[0], $+[0] - $-[0]); my $comment = substr($string, $start, $length); my $nbnewline = ($comment =~ tr/\n//); substr($string, $start, $length) = (' 'x ($length - $nbnewline)) . ("\n" x $nbnewline);#esmg;

    #
    ## Copy in a variable for speed
    #
    my $longest_match = $self->longest_match;

    if ($DEBUG_PROXY_ACTIONS && $is_debug) {
	$log->debugf('Ranking method  => %s', $self->ranking_method);
	$log->debugf('trace_terminals => %s', $self->trace_terminals);
	$log->debugf('trace_values    => %s', $self->trace_values);
        $log->debugf('trace_actions   => %s', $self->trace_actions);
	$log->debugf('Longest match   => %d', $longest_match);
    }

    my $rec = Marpa::R2::Recognizer->new(
	{
	    grammar => $grammarp,
	    ranking_method => $self->ranking_method,
	    trace_file_handle => $MARPA_TRACE_FILE_HANDLE,
	    trace_terminals => $self->trace_terminals,
	    trace_values => $self->trace_values,
	    trace_actions => $self->trace_actions,
	    closures => $okclosuresp
	});

    #
    ## In case there are lexer hints, since it our package that manage them, we
    ## resolve them now. Using the internal routine resolve_action of Marpa's
    ## recognizer.
    #
    my %lexactions = ();
    foreach (keys %{$lexhintsp}) {
      my $lhs = $_;
      $lexactions{$lhs} = {pre => undef, post => undef};
      foreach (qw/pre post/) {
        my $what = $_;
        if (exists($lexhintsp->{$lhs}->{$what})) {
          my $action = $lexhintsp->{$lhs}->{$what};
          #
          my $resolution;
          eval {$resolution = Marpa::R2::Internal::Recognizer::resolve_action($rec, $action); };
          if (ref($resolution) ne 'ARRAY') {
            if (! ref($resolution) && "$resolution") {
              $resolution =~ s/\s*$//;
              croak "$resolution\n";
            } else {
              croak "Failure to resolve $what lexer action $action\n";
            }
            $lexactions{$lhs}->{$what} = $resolution->[1];
          }
        }
      }
    }

    #  -------------
    ## Loop on input
    #  -------------
    my ($prev, $linenb, $colnb, $line) = (undef, 1, 0, '');
    my $pos;
    my $posline = BEGSTRINGPOSMINUSONE;
    my @matching_tokens;

    foreach ($[..$pos_max) {
	$pos = $_;
	pos($string) = $pos;
	my $c = substr($string, $pos, 1);

	if (defined($prev) && $prev eq "\n") {
	    $colnb = 0;
	    $line = '';
	    $posline = BEGSTRINGPOSMINUSONE;
	    ++$linenb;
	}

	++$colnb;
	$prev = $c;
	$line .= $prev;
	pos($line) = ++$posline;

        if ($DEBUG_PROXY_ACTIONS) {
	    $self->show_line(0, $linenb, $colnb, $pos, $pos_max, $line, $colnb);
        }

	#  ----------------------------------
	## Ask for the rules what they expect
	#  ----------------------------------
	my $expected_tokens = $rec->terminals_expected;
	if (@{$expected_tokens}) {

	    if ($DEBUG_PROXY_ACTIONS && $is_trace) {
		foreach (sort @{$expected_tokens}) {
		    $log->tracef('%sExpected %s: orig=%s, re=%s, string=%s, code=%s',
				 $self->position_trace($linenb, $colnb, $pos, $pos_max),
				 $_,
				 (exists($tokensp->{$_}->{orig})   && defined($tokensp->{$_}->{orig})   ? $tokensp->{$_}->{orig}   : ''),
				 (exists($tokensp->{$_}->{re})     && defined($tokensp->{$_}->{re})     ? $tokensp->{$_}->{re}     : ''),
				 (exists($tokensp->{$_}->{string}) && defined($tokensp->{$_}->{string}) ? $tokensp->{$_}->{string} : ''),
				 (exists($tokensp->{$_}->{code})   && defined($tokensp->{$_}->{code})   ? $tokensp->{$_}->{code}   : '')
			);
		}
	    }

	    @matching_tokens = ();
	    $self->lexer($string, $line, $tokensp, $pos, $posline, $linenb, $expected_tokens, \@matching_tokens, $longest_match);
	    if ($DEBUG_PROXY_ACTIONS && $is_debug) {
		foreach (@matching_tokens) {
		    $log->debugf('%sProposed %s: \'%s\', length=%d',
				 $self->position_trace($linenb, $colnb, $pos, $pos_max),
				 $_->[0],
				 ${$_->[1]},
				 $_->[2]);
		}
	    }

	    foreach (@matching_tokens) {
		$rec->alternative(@{$_});
	    }
	}

	my $ok = eval {$rec->earleme_complete; 1;} || 0;

	if (!$ok && @{$expected_tokens}) {
	    $log->errorf('Failed to complete earleme at line %s, column %s', $linenb, $colnb);
	    $self->show_line(1, $linenb, $colnb, $pos, $pos_max, $line, $colnb);
	    last;
	}

    }

    if ($DEBUG_PROXY_ACTIONS && $is_debug) {
	$log->debugf('Parsing stopped at position [%s/%s]', $pos, $pos_max);
    }
    $rec->end_input;

    #
    ## Evaluate all parse tree results
    #
    my @value_ref = ();
    my $value_ref = undef;
    my $nbparsing_with_failure = 0;
    do {
	$__PACKAGE__::failure = 0;
	$value_ref = $rec->value || undef;
	if (defined($value_ref)) {
	    if ($__PACKAGE__::failure == 0) {
		push(@value_ref, $value_ref);
	    }
	}
	if ($__PACKAGE__::failure != 0) {
	    ++$nbparsing_with_failure;
	}
    } while (defined($value_ref));

    if (! @value_ref) {
	if ($nbparsing_with_failure == 0) {
          $log->error('No parsing');
	} else {
	    if ($DEBUG_PROXY_ACTIONS && $is_debug) {
		$log->debugf('%d parse tree%s raised exception with unwanted term', $nbparsing_with_failure, ($nbparsing_with_failure > 1) ? 's' : '');
	    }
	}
      } else {
	if ($DEBUG_PROXY_ACTIONS && $is_debug) {
	    foreach (0..$#value_ref) {
		my $d = Data::Dumper->new([$value_ref[$_]]);
		my $s = $d->Dump;
		if ($DEBUG_PROXY_ACTIONS) {
		    #
		    ## we know $value_ref[$_] refers to an array ref
		    #
		    $log->debugf("[%d/%2d] Parse tree value:\n%s", $_, $#value_ref, Data::Dumper->new([ ${$value_ref[$_]} ])->Dump);
		} else {
		    #
		    ## Log::Any will to a Terse->Dump if needed
		    #
		    $log->debugf("[%d/%2d] Parse tree value: %s", $_, $#value_ref, ${$value_ref[$_]});
		}
	    }
	}
        if (! $self->multiple_parse_values && $#value_ref > 0) {
	    die scalar(@value_ref) . " parse values but multiple_parse_values setting is off\n";
        }
    }

    my $rc = wantarray ? @value_ref : shift(@value_ref);

    return $rc;
}

###############################################################################
# show_line
###############################################################################
sub show_line {
    my ($self, $errormodeb, $linenb, $col, $pos, $pos_max, $line, $colnb) = @_;

    my $position_trace = $self->position_trace($linenb, $colnb, $pos, $pos_max);
    my $pointer = ($colnb > 0 ? '-' x ($colnb-1) : '') . '^';
    $line =~ s/\t/ /g;
    if ($errormodeb != 0) {
	$log->errorf('%s%s', $position_trace, $line);
	$log->errorf('%s%s', $position_trace, $pointer);
    } else {
	$log->debugf('%s%s', $position_trace, $line);
	$log->debugf('%s%s', $position_trace, $pointer);
    }
}

1;

__END__
=head1 NAME

MarpaX::Import - Import grammars writen in xBNF into Marpa

=head1 SYNOPSIS

use MarpaX::Import;

use Log::Log4perl qw /:easy/;
use Log::Any::Adapter;

Log::Log4perl::init('log4perl.conf');
Log::Any::Adapter->set('Log4perl');

my $import = MarpaX::Import->new();

$import->startrules([qw/Expression/]);

my $grammar = $import->grammar(<<'END_OF_RULES'
Expression ::=
     /\d+/                        action => do_number
     | '(' Expression ')'         action => do_parens   assoc => group
    || Expression '**' Expression action => do_pow      assoc => right
    || Expression '*' Expression  action => do_multiply
     | Expression '/' Expression  action => do_divide
    || Expression '+' Expression  action => do_add
     | Expression '-' Expression  action => do_subtract
END_OF_RULES
);

my $closures = {
  do_number   => sub {shift; return $_[0]+0},
  do_parens   => sub {shift; return $_[1]},
  do_pow      => sub {shift; return $_[0] ** $_[2]},
  do_multiply => sub {shift; return $_[0] * $_[2]},
  do_divide   => sub {shift; return $_[0] / $_[2]},
  do_add      => sub {shift; return $_[0] + $_[2]},
  do_subtract => sub {shift; return $_[0] - $_[2]}
};

my $string = '42 * 2 + 7 / 3';

my $value = $ebnf->recognize($grammar, $string, $closures);

print "\"$string\" gives $value\n";

=head1 DESCRIPTION

MarpaX::Import exists to import xBNF grammar into Marpa. Currently, supported grammars can be a combinaison of

=over

=item * original BNF

=item * EBNF for XML

=item * Marpa's BNF

=back

ABNF and ISO-EBNF are being worked on.

The grammar is described using itself in the L<MarpaX::Import::Grammar> documentation. In the examples section, one can find import examples for the XML, SQL and YACC languages.

Important things to remember are:

=over

=item * MarpaX::Import requires that rules are all separated by at least one blank line.

=item * MarpaX::Import add supports to any perl5 regexp and to Regexp::Common.

=item * MarpaX::Import logs everything through Log::Any. See the examples on how to get log on/off/customized.

=item * any concatenation can be followed by action => ..., rank => ..., assoc => ..., separator => ..., proper => ...

=back

=head2 METHODS

=over

=item my $import = MarpaX::Import->new($)

Instanciates a MarpaX::Import object. Input, if defined, must a reference to a hash, with keys and values matching the methods described in the OPTION section below.

=item my $grammar = $import->grammar($)

Imports a grammar into Marpa and precompute it.

=item $grammar->recognize($$$)

Evaluates input v.s. imported grammar. First argument is the grammar as returned by MarpaX::Import->grammar(). Second argument is the string to evaluate. Third argument is all needed closures, in case the grammar has some action => ... statements. In array context, returns an array, otherwise returns the first parse tree value.

=back

=head2 OPTIONS

=over

=item $import->debug($)

MarpaX::Import is very verbose in debug mode, and that can be a performance penalty. This option controls the calls to tracing in debug mode. Input must be a scalar. Default is 0.

=item $import->char_escape($)

MarpaX::Import must know if perl's char escapes are implicit in strings or not. The perl char escapes themselves are \\a, \\b, \\e, \\f, \\n, \\r, \\t. Input must be a scalar. Default is 1.

=item $import->regexp_common($)

MarpaX::Import must know if Regexp::Common regular expressions can be part of regular expressions when importing a grammar. A regular expression in an imported grammar has the form /something/. Regexp::Common are suppported as: /$RE{something}{else}{and}{more}/. Input must be a scalar. Default is 1.

=item $import->char_class($)

MarpaX::Import must know if character classes are used in regular expressions. A character class has the form /[:someclass:]/. Input must be a scalar. Default is 1.

=item $import->trace_terminals($), $import->trace_values($), $import->trace_actions($), $import->infinite_action($), $import->default_action($), $import->action_object($), $import->bless_package($), $import->ranking_method($)

These options are passed as-is to Marpa. Please note that the Marpa logging is redirected to Log::Any.

=item $import->startrules($)

User can give a list of rules that will be the startrule. Input must be a reference to an array. Default is [qw/:start/].

=item $import->discardrules($)

User can give a list of rules that will be the discard. Input must be a reference to an array. Default is [qw/:discard/].

=item $import->auto_rank($)

Rules can be auto-ranked, i.e. if this option is on every concatenation of a rule has a rank that is the previous rank minus 1. Start rank value is 0. Input must be a scalar. Default is 0. This leave to the read's intuition: what is the default ranking method when calling Marpa, then. It is 'high_rule_only' and this is fixed. If this option is on, then the use of rank => ... is forbiden in the grammar. Input must be a scalar. Default is 0.

=item $import->multiple_parse_values($)

Ambiguous grammars can give multiple parse tree values. If this option is set to false, then MarpaX::Import will croak, giving in its log the location of the divergence from actions point of view. Input must be a scalar. Default is 0.

=back

=head2 EXPORT

None by default.

=head1 SEE ALSO

L<Marpa::R2>, L<Regexp::Common>, L<W3C's EBNF 5th edition|http://www.w3.org/TR/2008/REC-xml-20081126/>.

=head1 AUTHOR

Jean-Damien Durand, E<lt>jeandamiendurand@free.frE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012 by Jean-Damien Durand

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.14.2 or,
at your option, any later version of Perl 5 you may have available.


=cut
