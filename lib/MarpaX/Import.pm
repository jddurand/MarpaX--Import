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

autoflush STDOUT 1;
#
## Support of Marpa's BNF, W3C's EBNF
##
## We add support for an optional and useless [RULENUMBER] before every rule
## We add support for true perl regexp /regexp/
## As in Stuifzand BNF grammar, the action => action to give an action
## In addtion rank => number is possible
## There is no notion of separator, so no proper => option.
##
## This module started after reading "Sample CSS Parser using Marpa::XS"
## at https://gist.github.com/1511584
#
require Exporter;
use AutoLoader qw(AUTOLOAD);
use Carp;

our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw// ] );
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = qw//;

our $VERSION = '0.01';

our $RE_SYMBOL_BALANCED = $RE{balanced}{-parens=>'<>'};
our $ACTION_FIRST_ARG = sprintf('%s::%s',__PACKAGE__, 'action_first_arg');
our $ACTION_MAKE_ARRAYP = sprintf('%s::%s',__PACKAGE__, 'action_make_arrayp');
our $ACTION_ARGS = sprintf('%s::%s',__PACKAGE__, 'action_args');
our $ACTION_TWO_ARGS_RECURSIVE = sprintf('%s::%s',__PACKAGE__, 'action_two_args_recursive');
our $ACTION_EMPTY = sprintf('%s::%s',__PACKAGE__, 'action_empty');

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

#
## These are the comments that we will be removed from the grammar
#
our $WEBCODE_RE = qr/$RE{balanced}{-begin => '--p|--i|--h2|--h3|--bl|--small'}{-end => '--\/p|--\/i|--\/h2|--\/h3|--\/bl|--\/small'}/;

our %TOKENS = (
    'DIGITS'          => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*([[:digit:]]+)/, undef),
    'COMMA'           => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(,)/, undef),
    'RULESEP'         => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(::=|:|=)/, undef),
    'PIPE'            => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(\|{1,2})/, undef),
    'MINUS'           => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(\-)/, undef),
    'STAR'            => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(\*)/, undef),
    'PLUS'            => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(\+|\.\.\.)/, undef),
    'RULEEND'         => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(;|\.)/, undef),
    'QUESTIONMARK'    => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(\?)/, undef),
    'STRING'          => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*($RE{delimited}{-delim=>q{'"}})/, undef),
    'WORD'            => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*([[:word:]]+)/, undef),
    'LBRACKET'        => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(\[)/, undef),
    'RBRACKET'        => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(\])/, undef),
    'LPAREN'          => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(\()/, undef),
    'RPAREN'          => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(\))/, undef),
    'LCURLY'          => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(\{)/, undef),
    'RCURLY'          => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(\})/, undef),
    'SYMBOL_BALANCED' => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*($RE_SYMBOL_BALANCED)/, undef),
    'HEXCHAR'         => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(#x([[:xdigit:]]+))/, undef),
    'CHAR_RANGE'      => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(\[(#x[[:xdigit:]]+|[^\^][^[:cntrl:][:space:]]*?)(?:\-(#x[[:xdigit:]]+|[^[:cntrl:][:space:]]+?))?\])/, undef),
    'CARET_CHAR_RANGE'=> __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*(\[\^(#x[[:xdigit:]]+|[^[:cntrl:][:space:]]+?)(?:\-(#x[[:xdigit:]]+|[^[:cntrl:][:space:]]+?))?\])/, undef),
    'ACTION'          => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*action[ \f\t\r]*=>[ \f\t\r]*([[:alpha:]][[:word:]]*)/, undef),
    'RANK'            => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*rank[ \f\t\r]*=>[ \f\t\r]*(\-?[[:digit:]]+)/, undef),
    'ASSOC'           => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*assoc[ \f\t\r]*=>[ \f\t\r]*(left|group|right)/, undef),
    'RULENUMBER'      => __PACKAGE__->make_token('', undef, qr/\G[[:space:]]*(\[[[:digit:]][^\]]*\])/, undef),
    'REGEXP'          => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*($RE{delimited}{-delim=>q{\/}})/, undef),
    'SPACES'          => __PACKAGE__->make_token('', undef, qr/\G([[:space:]]+)/, undef),
    'EOL'             => __PACKAGE__->make_token('', undef, qr/\G([ \f\t\r]*\n)/, undef),
    'EOL_EOL_ETC'     => __PACKAGE__->make_token('', undef, qr/\G((?:[ \f\t\r]*\n){2,})/, undef),
    'IGNORE'          => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*($RE{balanced}{-begin => '[wfc|[WFC|[vc|[VC'}{-end => ']|]|]|]'})/, undef),
    'COMMENT'         => __PACKAGE__->make_token('', undef, qr/\G[ \f\t\r]*\n?[ \f\t\r]*($RE{comment}{C})/, undef),
    );

our $GRAMMAR = Marpa::R2::Grammar->new
    (
     {
	 start                => 'startrule',
	 terminals            => [keys %TOKENS],
	 actions              => __PACKAGE__,
	 trace_file_handle    => $MARPA_TRACE_FILE_HANDLE,
	 rules                =>
	     [
	      { lhs => 'spaces_maybe',            rhs => [qw/SPACES/],                          action => '_action_spaces_maybe' },
	      { lhs => 'spaces_maybe',            rhs => [qw//],                                action => '_action_spaces_maybe' },

	      { lhs => 'startrule',               rhs => [qw/spaces_maybe rule more_rule_any/], action => '_action_startrule' },
	      { lhs => 'more_rule',               rhs => [qw/EOL_EOL_ETC rule/],                action => '_action_more_rule' },
	      { lhs => 'more_rule_any',           rhs => [qw/more_rule/], min => 0,             action => '_action_more_rule_any' },

	      { lhs => 'symbol_balanced',         rhs => [qw/SYMBOL_BALANCED/],                 action => '_action_symbol_balanced' },

	      { lhs => 'word',                    rhs => [qw/WORD/],                            action => '_action_word' },

	      { lhs => 'symbol',                  rhs => [qw/symbol_balanced/],                 action => '_action_symbol' },
	      { lhs => 'symbol',                  rhs => [qw/word/],                            action => '_action_symbol' },

              { lhs => 'rulenumber_maybe',        rhs => [qw/RULENUMBER/],                      action => '_action_rulenumber_maybe' },
              { lhs => 'rulenumber_maybe',        rhs => [qw//],                                action => '_action_rulenumber_maybe' },

              { lhs => 'ruleend_maybe',           rhs => [qw/RULEEND/],                         action => '_action_ruleend_maybe' },
              { lhs => 'ruleend_maybe',           rhs => [qw//],                                action => '_action_ruleend_maybe' },

	      { lhs => 'rule',                    rhs => [qw/rulenumber_maybe symbol RULESEP expression ruleend_maybe/], action => '_action_rule' },
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
              { lhs => 'hint',                    rhs => [qw/RANK/],                            action => '_action_hint_rank' },
              { lhs => 'hint',                    rhs => [qw/ACTION/],                          action => '_action_hint_action' },
              { lhs => 'hint',                    rhs => [qw/ASSOC/],                           action => '_action_hint_assoc' },
              { lhs => 'hint_any',                rhs => [qw/hint/], min => 0,                  action => '_action_hint_any' },
              { lhs => 'hints_maybe',             rhs => [qw/hint_any/],                        action => '_action_hints_maybe' },
              { lhs => 'hints_maybe',             rhs => [qw//],                                action => '_action_hints_maybe' },
	      # |   #
	      # |   # /\
	      # |   # || action => [ [ [ @rhs ], { hints } ] ]
	      # |   # ||
	      # |   #
	      { lhs => 'more_concatenation',      rhs => [qw/PIPE concatenation/],              action => '_action_more_concatenation' },
	      { lhs => 'more_concatenation_any',  rhs => [qw/more_concatenation/], min => 0,    action => '_action_more_concatenation_any' },
	      # |   #
	      # |   # /\
	      # |   # || action => [ [ @rhs ], { hints } ]
	      # |   # ||
	      # |   #
	      { lhs => 'dumb',                    rhs => [qw/IGNORE/],                          action => '_action_ignore' },
	      { lhs => 'dumb',                    rhs => [qw/COMMENT/],                         action => '_action_comment' },
	      { lhs => 'dumb_any',                rhs => [qw/dumb/], min => 0,                  action => '_action_dumb' },

	      { lhs => 'concatenation',           rhs => [qw/exception_any hints_maybe dumb_any/],  action => '_action_concatenation' },
	      { lhs => 'concatenation_notempty',  rhs => [qw/exception_many hints_maybe dumb_any/], action => '_action_concatenation' },
	      # |   #
	      # |   # /\
	      # |   # || action => [ @rhs ]
	      # |   # ||
	      # |   #
	      { lhs => 'comma_maybe',             rhs => [qw/COMMA/],                           action => '_action_comma_maybe' },
	      { lhs => 'comma_maybe',             rhs => [qw//],                                action => '_action_comma_maybe' },

	      { lhs => 'exception_any',           rhs => [qw/exception/], min => 0,              action => '_action_exception_any' },
	      { lhs => 'exception_many',          rhs => [qw/exception/], min => 1,              action => '_action_exception_many' },
	      { lhs => 'exception',               rhs => [qw/term more_term_maybe comma_maybe/], action => '_action_exception' },
	      # |   #
	      # |   # /\
	      # |   # || action => rhs_as_string or undef
	      # |   # ||
	      # |   #
	      { lhs => 'more_term',               rhs => [qw/MINUS term/],                      action => '_action_more_term' },

	      { lhs => 'more_term_maybe',         rhs => [qw/more_term/],                       action => '_action_more_term_maybe' },
	      { lhs => 'more_term_maybe',         rhs => [qw//],                                action => '_action_more_term_maybe' },

	      { lhs => 'term',                    rhs => [qw/factor/],                          action => '_action_term' },
	      # |   #
	      # |   # /\
	      # |   # || action => quantifier_as_string or undef
	      # |   # ||
	      # |   #
	      { lhs => 'quantifier',              rhs => [qw/STAR/],                            action => '_action_quantifier' },
	      { lhs => 'quantifier',              rhs => [qw/PLUS/],                            action => '_action_quantifier' },
	      { lhs => 'quantifier',              rhs => [qw/QUESTIONMARK/],                    action => '_action_quantifier' },
	      { lhs => 'quantifier_maybe',        rhs => [qw/quantifier/],                      action => '_action_quantifier_maybe' },
	      { lhs => 'quantifier_maybe',        rhs => [qw//],                                action => '_action_quantifier_maybe' },
	      # |   #
	      # |   # /\
	      # |   # || action => rhs_as_string or undef
	      # |   # ||
	      # |   #
	      { lhs => 'hexchar_many',            rhs => [qw/HEXCHAR/], min => 1, action => '_action_hexchar_many' },
	      #
	      ## Rank 4
	      #  ------
              # Special case of [ { XXX }... ] meaning XXX*, that we want to catch first
              # Special case of [ XXX... ] meaning XXX*, that we want to catch first
	      { lhs => 'factor',                  rhs => [qw/LBRACKET LCURLY expression_notempty RCURLY PLUS RBRACKET/], rank => 4, action => '_action_factor_lbracket_lcurly_expression_rcurly_plus_rbracket' },
	      { lhs => 'factor',                  rhs => [qw/LBRACKET symbol PLUS RBRACKET/], rank => 4, action => '_action_factor_lbracket_symbol_plus_rbracket' },
              # Special case of DIGITS * [ XXX ] meaning XXX{0..DIGIT}, that we want to catch first
	      { lhs => 'factor',                  rhs => [qw/DIGITS STAR LBRACKET symbol RBRACKET/], rank => 4, action => '_action_factor_digits_star_lbracket_symbol_rbracket' },
              # Special case of DIGITS * { XXX } meaning XXX{1..DIGIT}, that we want to catch first
	      { lhs => 'factor',                  rhs => [qw/DIGITS STAR LCURLY symbol RCURLY/], rank => 4, action => '_action_factor_digits_star_lcurly_symbol_rcurly' },
	      #
	      ## When a symbol is seen as symbol balanced, then no ambiguity.
	      ## But when a symbol is simply a word this is BAD writing of EBNF.
	      ## Therefore, IF your symbol contains '-' it can very well be cached in a CHAR_RANGE in the following
	      ## situation: [ bad-symbol ]
	      ## That's exactly why, when you have an EBNF, you should ALWAYS make sure that
	      ## all symbols are writen with the <> form
	      ## We give higher precedence everywere symbol is in a factor rule and appears in the <> form
	      #
	      { lhs => 'factor',                  rhs => [qw/symbol_balanced quantifier/], rank => 4, action => '_action_factor_symbol_balanced_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/symbol_balanced/], rank => 4, action => '_action_factor_symbol_balanced_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/DIGITS STAR symbol_balanced/], rank => 4, action => '_action_factor_digits_star_symbol_balanced' },

	      #
	      ## Rank 3
	      #  ------
	      # We want strings to have a higher rank, because in particular a string can contain the MINUS character...
	      { lhs => 'factor',                  rhs => [qw/STRING quantifier/], rank => 3, action => '_action_factor_string_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/STRING/], rank => 3, action => '_action_factor_string_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/DIGITS STAR STRING/], rank => 3, action => '_action_factor_digits_star_string' },
	      #
	      ## Rank 2
	      #  ------
	      { lhs => 'factor',                  rhs => [qw/CARET_CHAR_RANGE quantifier/], rank => 2, action => '_action_factor_caret_char_range_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/CARET_CHAR_RANGE/], rank => 2, action => '_action_factor_caret_char_range_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/CHAR_RANGE quantifier/], rank => 2, action => '_action_factor_char_range_quantifier_maybe'},
	      { lhs => 'factor',                  rhs => [qw/CHAR_RANGE/], rank => 2, action => '_action_factor_char_range_quantifier_maybe'},
	      #
	      ## Rank 1
	      #  ------
	      { lhs => 'factor',                  rhs => [qw/REGEXP/], rank => 1, action => '_action_factor_regexp' },
	      { lhs => 'factor',                  rhs => [qw/LPAREN expression_notempty RPAREN quantifier/], rank => 1, action => '_action_factor_expression_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/LPAREN expression_notempty RPAREN/], rank => 1, action => '_action_factor_expression_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/LCURLY expression_notempty RCURLY quantifier/], rank => 1, action => '_action_factor_expression_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/LCURLY expression_notempty RCURLY/], rank => 1, action => '_action_factor_expression_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/LBRACKET expression_notempty RBRACKET/], rank => 1, action => '_action_factor_expression_maybe' },
	      { lhs => 'factor',                  rhs => [qw/DIGITS STAR expression_notempty/], rank => 1, action => '_action_factor_digits_star_expression' },
	      { lhs => 'factor',                  rhs => [qw/word quantifier/], rank => 1, action => '_action_factor_word_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/word/], rank => 1, action => '_action_factor_word_quantifier_maybe' },
	      { lhs => 'factor',                  rhs => [qw/DIGITS STAR word/], rank => 1, action => '_action_factor_digits_star_word' },
	      #
	      ## Rank 0
	      #  ------
	      { lhs => 'factor',                  rhs => [qw/hexchar_many quantifier/], rank => 0, action => '_action_factor_hexchar_many_quantifier_maybe' },
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
## We support ${space_re}, ${eof_re} at run-time
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

#
## Support of Regexp::Common
## C.f. http://perldoc.net/Regexp/Common.pm
##
## This will be applied to regexp //
#  -------------------------------------------------------------------------------
our $REGEXP_COMMON_RE = qr/\$RE($RE{balanced}{-parens=>'{}'}+)/;

#    ----                         ---------------  -------------
#    Name                         Possible_values  Default_value
#    ----                         ---------------  -------------
our %OPTION_DEFAULT = (
    'style'                  => [[qw/Moose perl5/], 'perl5'           ],
    'space_re'               => [undef            , qr/[[:space:]]*/  ],
    'debug'                  => [undef            , 0                 ],
    'lex_re_m_modifier'      => [undef            , 0                 ],
    'lex_re_s_modifier'      => [undef            , 0                 ],
    'char_escape'            => [undef            , 1                 ],
    'regexp_common'          => [undef            , 1                 ],
    'char_class'             => [undef            , 1                 ],
    'trace_terminals'        => [undef            , 0                 ],
    'trace_values'           => [undef            , 0                 ],
    'trace_actions'          => [undef            , 0                 ],
    'action_failure'         => [undef            , '_action_failure' ],
    'startrules'             => [undef            , [qw/startrule/]   ],
    'generated_lhs_format'   => [undef            , 'generated_lhs_%06d' ],
    'generated_token_format' => [undef            , 'GENERATED_TOKEN_%06d' ],
    'eof_aware'              => [[qw/0 1/]        , 1                 ],
    'default_assoc'          => [[qw/left group right/], 'left'       ],
    # 'position_trace_format'  => [undef            , '[Line:Col %4d:%03d, Offset:offsetMax %6d/%06d] ' ],
    'position_trace_format'  => [undef            , '[%4d:%4d] ' ],
    'eof_re'                 => [undef            , qr/\G[[:space:]]*\z/ ],
    'infinite_action'        => [[qw/fatal warn quiet/], 'fatal'      ],
    'word_boundary'          => [[qw/0 1/]        , 0                 ],
    'auto_rank'              => [[qw/0 1/]        , 0                 ],
    'multiple_parse_values'  => [[qw/0 1/]        , 0                 ],
    );

###############################################################################
# reset_options
###############################################################################
sub reset_options {
    my $self = shift;

    my $rc = {};

    foreach (keys %OPTION_DEFAULT) {
	$rc->{$_} = $self->{$_} = $OPTION_DEFAULT{$_}->[1];
    }

    return $rc;
}

###############################################################################
# new
###############################################################################
sub option_value_is_ok {
    my ($self, $name, $ref, $value) = @_;
    my $possible = $OPTION_DEFAULT{$name}->[0];

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
	croak "No option value for $name\n";
    } elsif (ref($value) ne $ref) {
	croak "Bad option value for $name (is a " . ref($value) . ", expecting a $ref)\n";
    }
}

###############################################################################
# new
###############################################################################
sub new {
    my ($class, $optp) = @_;

    if (defined($optp)) {
	if (ref($optp) ne 'HASH') {
	    croak "Options must a reference to a hash\n";
	}
    }

    my $self  = {};
    bless($self, $class);

    foreach (keys %OPTION_DEFAULT) {
	my $value = exists($optp->{$_}) ? $optp->{$_} : $OPTION_DEFAULT{$_}->[1];
	$self->$_($value);
    }

    return $self;
}

###############################################################################
# log_debug
###############################################################################
sub log_debug {
  my $self = shift;

  return ($self->debug && $log->is_debug) ? 1 : 0;
}

###############################################################################
# make_token_if_not_exist
###############################################################################
sub make_token_if_not_exist {
    my ($self, $closure, $tokensp, $nb_token_generatedp, $token, $orig, $re, $code) = @_;

    $closure =~ s/\w+/  /;
    my $innerclosure = "$closure  ";
    $closure .= 'make_token_if_not_exist';
    $self->dumparg_in($closure, $orig, $re, $code);

    my @token = grep {$tokensp->{$_}->{orig} eq $orig} keys %{$tokensp};
    if (! @token) {
	if (! defined($token)) {
	    $token = $self->make_token_name($closure, $nb_token_generatedp);
	}
	if ($self->log_debug) {
	    $log->debugf('    %s Adding token %s for %s => %s', $innerclosure, $token || '', $orig || '', $re || '');
	}
	$tokensp->{$token} = $self->make_token($closure, $orig, $re, $code);
    } else {
	if ($self->log_debug) {
	    $log->debugf('    %s Token %s for %s => %s already exist', $innerclosure, $token[0] || '', $orig || '', $re || '');
	}
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
    my ($self, $closure, $orig, $re, $code) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_token';
    $self->dumparg_in($closure, $orig, $re, $code);

    my $rc = {
	orig => $orig,
	re => $re,
	#
	## We provide a default CODE ref if this is not given in the arguments
	#
	code => $code ||
	    sub {
		my ($self, $stringp, $tokensp, $pos, $token_name, $closuresp) = @_;
		my $re = $tokensp->{$token_name}->{re};
		my $lex_re_m_modifier = $self->lex_re_m_modifier;
		my $lex_re_s_modifier = $self->lex_re_s_modifier;
		pos($$stringp) = $pos;
		my $rc = undef;
		if ((! $lex_re_m_modifier && ! $lex_re_s_modifier) ? $$stringp =~ m/$re/g   :
		    (  $lex_re_m_modifier &&   $lex_re_s_modifier) ? $$stringp =~ m/$re/smg :
		    (  $lex_re_m_modifier                        ) ? $$stringp =~ m/$re/mg  : $$stringp =~ m/$re/sg) {
		    my $matched_len = $+[0] - $-[0];
		    my $matched_value = undef;
		    if ($#- > 0) { # Captured a value
			my $this = substr($$stringp, $-[1], $+[1] - $-[1]);
			$matched_value = \$this;
		    }
		    $rc = [$token_name, $matched_value, $matched_len];
		}
		return $rc;
	}
    };

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
# add_rule
###############################################################################
sub add_rule {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $h) = @_;

    $closure =~ s/\w+/  /;
    my $innerclosure = "$closure  ";
    $closure .= 'add_rule';
    $self->dumparg_in($closure, $h);

    my $lhs = $h->{lhs};
    my $min    = (exists($h->{min})    && defined($h->{min}))    ? $h->{min}    : undef;
    my $rank   = (exists($h->{rank})   && defined($h->{rank}))   ? $h->{rank}   : undef;
    my $action = (exists($h->{action}) && defined($h->{action})) ? $h->{action} : undef;

    #
    ## If we refer a token, RHS will be the generated token
    #
    my $token = undef;
    if (exists($h->{re})) {
	my @token = grep {$tokensp->{$_}->{orig} eq $h->{orig}} keys %{$tokensp};
	if (! @token) {
	    $token = $self->make_token_name($closure, $nb_token_generatedp);
            if ($self->log_debug) {
		$log->debugf('    %s Adding token %s for %s => %s', $innerclosure, $token || '', $h->{orig} || '', $h->{re} || '');
	    }
	    $tokensp->{$token} = $self->make_token($closure, $h->{orig}, $h->{re}, $h->{code});
	} else {
            if ($self->log_debug) {
		$log->debugf('    %s Token %s for %s => %s already exist', $innerclosure, $token[0] || '', $h->{orig} || '', $h->{re} || '');
	    }
	    $token = $token[0];
	}
	#
	## If there no min nor action, then the wanted rule is strictly equivalent to
	## the token
	#
	if (! defined($min) && ! defined($action)) {
	    return $token;
	}
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
    ## this quantifier, remove all intermediary steps
    #
    if ($self->log_debug) {
      $log->debugf('    %s Adding rule {lhs => %s, rhs => [qw/%s/], min => %s, action => %s, rank => %s}',
		   $innerclosure,
		   $lhs,
		   $rhsp,
		   $min || 'undef',
		   $action || 'undef',
		   $rank || 'undef');
    }
    my $rc = $lhs;
    if (defined($min) && ($min == 0)) {
	#
	## Marpa does not like nullables that are on the rhs of a counted rule
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
	##
	## Many thanks to rns (google group marpa-parser)
	#
	## This is the original rule, but without the min => 0
	## action will return [ original_output ]
        #
	push(@{$rulesp->{$lhs}}, {lhs => $lhs, rhs => $rhsp, action => $ACTION_ARGS});
        #
        ## action will return [ original_output ]
        #
	my $lhsdup = $self->make_lhs_name($closure, $nb_lhs_generatedp);
	push(@{$rulesp->{$lhs}}, {lhs => $lhsdup, rhs => [ $lhs ], action => $ACTION_FIRST_ARG});

	my $lhsmin0 = $self->make_lhs_name($closure, $nb_lhs_generatedp);
	my $lhsfake = $self->make_lhs_name($closure, $nb_lhs_generatedp);
	$self->make_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $lhsmin0,
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
			   [ '||', [                         ], { action => $ACTION_EMPTY } ]
			  ]
			 ]
	    );
	#
	## This is the fake rule that make sure that the output of rule* is always in the form [ [...], [...], ... ]
	## action will return [ [ original_output1 ], [ original_output2 ], ... [ original_output ] ]
	push(@{$rulesp->{$lhs}}, {lhs => $lhsfake, rhs => [ $lhsmin0 ], action => $ACTION_FIRST_ARG});

	if (defined($action)) {
	    my $lhsfinal = $self->make_lhs_name($closure, $nb_lhs_generatedp);
	    $rc = $lhsfinal;
	    #
	    ## This is the final rule that mimic the arguments min => 0 would send
	    #
	    push(@{$rulesp->{$lhs}}, {lhs => $lhsfinal, rhs => [ $lhsfake ], action => $action, rank => $rank});
	} else {
	    $rc = $lhsfake;
	}
    } else {
	push(@{$rulesp->{$lhs}}, {lhs => $lhs, rhs => $rhsp, min => $min, action => $action, rank => $rank});
    }

    $self->dumparg_out($closure, $rc);

    return $rc;
}

###############################################################################
# range_to_r1_r2
###############################################################################
sub range_to_r1_r2 {
    my ($self, $re, $rc) = @_;

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
# action_push
###############################################################################
sub action_push {
    my ($self, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $scratchpad, $inc_startrule_tree_number, $action, @args) = @_;
    if (! exists($scratchpad->{actions})) {
	$scratchpad->{actions} = {};
    }
    if (! exists($scratchpad->{startrule_tree_number})) {
	$scratchpad->{startrule_tree_number} = 0;
    }
    my $startrule_tree_number = $scratchpad->{startrule_tree_number};
    if (! exists($scratchpad->{actions}->{$startrule_tree_number})) {
	$scratchpad->{actions}->{$startrule_tree_number} = [];
    }
    #
    ## undef will be replaced by $rc
    #
    my $this = [ $action, @args ];
    push(@{$scratchpad->{actions}->{$startrule_tree_number}}, $this);

    if ($scratchpad->{startrule_tree_number} > 0 && ! $self->multiple_parse_values) {
	if (! exists($scratchpad->{divergence_analyzed})) {
	    $scratchpad->{divergence_analyzed} = 0;
	}
	if ($scratchpad->{divergence_analyzed} == 0) {
	    #
	    ## Give a warning at where the parse tree started to diverge
	    #
	    my $previous_tree = $scratchpad->{actions}->{$scratchpad->{startrule_tree_number} - 1};
	    my $current_tree  = $scratchpad->{actions}->{$scratchpad->{startrule_tree_number}};

	    my $min = $#{$previous_tree} < $#{$current_tree} ? $#{$previous_tree} : $#{$current_tree};

	    my @previous = ();
	    my @current = ();
	    
	    #
	    ## Prepare a big regexp with generated things so that we are disturbed
	    ## by them
	    #
	    my $re_generated_lhs = undef;
	    if (%{$self->{generated_lhs}}) {
		my $this = join('|', map {quotemeta("'$_'")} keys %{$self->{generated_lhs}});
		$re_generated_lhs = qr/$this/;
	    }
	    my $re_generated_token = undef;
	    if (%{$self->{generated_token}}) {
		my $this = join('|', map {quotemeta("'$_'")} keys %{$self->{generated_token}});
		$re_generated_token = qr/$this/;
	    }
	    foreach (0..$min) {
		my $i = $_;
		#
		## Everything that matched generated things will be different, so we
		## ignore them in the comparison.
		## The problem is that the format string is opened, so instead we
		## use existence in %rules and %tokens
		#
		my $dprevious = Data::Dumper->new($previous_tree->[$i]);
		$dprevious->Terse(1);
		$dprevious->Indent(0);
		my $previous = $dprevious->Dump;
		$previous =~ s/$re_generated_lhs/'__generated__lhs'/g;
		$previous =~ s/$re_generated_token/'__generated__token'/g;

		my $dcurrent  = Data::Dumper->new($current_tree->[$i]);
		$dcurrent->Terse(1);
		$dcurrent->Indent(0);
		my $current  = $dcurrent->Dump;
		$current =~ s/$re_generated_lhs/'__generated__lhs'/g;
		$current =~ s/$re_generated_token/'__generated__token'/g;

		push(@previous, $previous);
		push(@current, $current);
		if ($previous ne $current) {
		    $log->errorf("Parse tree divergence detected");
		    $log->errorf("Level %2d: Tree dump up to the divergence follows", $scratchpad->{startrule_tree_number} - 1);
		    foreach (@previous) {
			$log->errorf("Level %2d: %s", $scratchpad->{startrule_tree_number} - 1, $_);
		    }
		    $log->errorf("Level %2d: Tree dump up to the divergence follows", $scratchpad->{startrule_tree_number});
		    foreach (@current) {
			$log->errorf("Level %2d: %s", $scratchpad->{startrule_tree_number}, $_);
		    }
		    $scratchpad->{divergence_analyzed} = 1;
		    # last;
		    croak("Parse tree divergence detected");
		}
	    }
	}
    }

    if ($inc_startrule_tree_number > 0) {
	$scratchpad->{startrule_tree_number} += $inc_startrule_tree_number;
    }

    return $scratchpad;
};

###############################################################################
# action_pop
###############################################################################
sub action_pop {
    my ($self, $scratchpad, $rc) = @_;
    my $startrule_tree_number = $scratchpad->{startrule_tree_number};
    my $this = ${$scratchpad->{actions}->{$startrule_tree_number}}[-1];
    # $this->[1] = $rc;

    return $this;
};

###############################################################################
# dumparg
###############################################################################
sub dumparg {
    my $self = shift;
    if (ref($self) eq __PACKAGE__ && $self->log_debug) {
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
    my $grammar = $Marpa::R2::Context::grammar;
    my $what = '';
    my $lhs = '';
    my @rhs = ();
    if (defined($rule_id) && defined($grammar)) {
      my ($lhs, @rhs) = $grammar->rule($rule_id);
      $what = sprintf('%s ::= %s ', $lhs, join(' ', @rhs));
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
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $min, $action, @rhs) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_concat';
    $self->dumparg_in("$closure [min=" . (defined($min) ? $min : 'undef') . ", action=" . (defined($action) ? $action : 'undef') . "]", @rhs);

    #
    ## If:
    ## - there is a single rhs
    ## - there is no min
    ## - there is no action
    ##
    ## then we are asked for an LHS that is strictly equivalent to the single RHS
    #
    my @okrhs = grep {defined($_)} @rhs;
    my $rc = undef;
    if (
	$#okrhs == 0 &&
	! defined($min) &&
	! defined($action)) {
	$rc = $okrhs[0];
    } elsif ($#okrhs >= 0) {
	$rc = $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, {rhs => [ @okrhs ], min => $min, action => $action});
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
    my $rc = (defined($quantifier) && ($quantifier =~ $TOKENS{PLUS}->{re})) ? 1 : 0;
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
    my $rc = (defined($quantifier) && ($quantifier =~ $TOKENS{STAR}->{re})) ? 1 : 0;
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
    my $rc = (defined($quantifier) && ($quantifier =~ $TOKENS{QUESTIONMARK}->{re})) ? 1 : 0;
    $self->dumparg_out($closure, $rc);

    return $rc;

}

###############################################################################
# make_factor_expression_quantifier_maybe
###############################################################################
sub make_factor_expression_quantifier_maybe {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $expressionp, $quantifier_maybe) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_factor_expression_quantifier_maybe';
    $self->dumparg_in("$closure [expressionp=$expressionp, quantifier=" . (defined($quantifier_maybe) ? $quantifier_maybe : 'undef') . "]");
    #
    ## We make a rule out of this expression
    #
    my $lhs = $self->make_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, undef, $expressionp);
    #
    ## And we quantify it
    #
    my $rc = $self->make_factor_quantifier_maybe($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, undef, undef, $lhs, $quantifier_maybe);

    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# make_factor_char_range_quantifier_maybe
###############################################################################
sub make_factor_char_range_quantifier_maybe {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $range, $range_type, $quantifier_maybe) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_factor_range_quantifier_maybe';
    $self->dumparg_in("$closure [range=$range, range_type=$range_type, quantifier=" . (defined($quantifier_maybe) ? $quantifier_maybe : 'undef') . "]");

    my $orig = my $string = $range;
    my ($r1, $r2) = $self->range_to_r1_r2($TOKENS{$range_type}->{re}, $string);
    if ($self->char_escape) {
	$self->handle_meta_character($closure, \$r1, $CHAR_ESCAPE_RE, \%CHAR_ESCAPE);
	$self->handle_meta_character($closure, \$r2, $CHAR_ESCAPE_RE, \%CHAR_ESCAPE);
    }

    my $space_re = $self->space_re;
    my $rc;
    if ($self->char_class) {
	my $eof_re = $self->eof_re;
	my %char_class = (%CHAR_CLASS,
			  quotemeta("\${space_re}") => ${space_re},
			  quotemeta("\${eof_re}") => ${eof_re});
	my $char_class_re = $self->char_class_re(\%char_class);
	$self->handle_meta_character($closure, \$r1, $char_class_re, \%char_class);
	$self->handle_meta_character($closure, \$r2, $char_class_re, \%char_class);
    }
    if ($self->is_plus_quantifier($closure, $quantifier_maybe)) {
	#
	## '+' can be embedded in the regexp
	#
	my $re;
	if ($range_type eq 'CHAR_RANGE') {
	    $re = (length($r2) > 0) ? qr/\G${space_re}([${r1}-${r2}]+)/ : qr/\G${space_re}([${r1}]+)/;
	} else {
	    $re = (length($r2) > 0) ? qr/\G${space_re}([^${r1}-${r2}]+)/ : qr/\G${space_re}([^${r1}]+)/;
	}
	$rc = $self->make_factor_quantifier_maybe($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, undef, "${range}+", $re, $quantifier_maybe);
    } else {
	my $re;
	if ($range_type eq 'CHAR_RANGE') {
	    $re = (length($r2) > 0) ? qr/\G${space_re}([${r1}-${r2}])/ : qr/\G${space_re}([${r1}])/;
	} else {
	    $re = (length($r2) > 0) ? qr/\G${space_re}([^${r1}-${r2}])/ : qr/\G${space_re}([^${r1}])/;
	}
	$rc = $self->make_factor_quantifier_maybe($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, undef, $range, $re, $quantifier_maybe);
    }

    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# make_factor_string_quantifier_maybe
###############################################################################
sub make_factor_string_quantifier_maybe {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $string, $quantifier_maybe) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_factor_string_quantifier_maybe';
    $self->dumparg_in("$closure [string=$string, quantifier=" . (defined($quantifier_maybe) ? $quantifier_maybe : 'undef') . "]");

    my $orig = $string;
    my $was = substr($string, $[, 1, '');
    substr($string, $[ - 1, 1) = '';
    my $quoted = quotemeta($string);
    if ($self->char_escape && $was eq '"') {
	$self->handle_meta_character($closure, \$quoted, $CHAR_ESCAPE_RE, \%CHAR_ESCAPE);
    }
    my $space_re = $self->space_re;
    my $word_boundary = $self->word_boundary;
    my $boundary = ($word_boundary && ($string =~ /^[[:word:]]+$/)) ? '\\b' : '';
    my $rc;
    if ($self->is_plus_quantifier($closure, $quantifier_maybe)) {
	#
	## '+' can be embedded in the regexp
	#
	my $re = qr/\G${space_re}(${quoted}+)${boundary}/;
	$rc = $self->make_factor_quantifier_maybe($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, undef, "${string}+", $re, $quantifier_maybe);
    } else {
	my $re = qr/\G${space_re}(${quoted})${boundary}/;
	$rc = $self->make_factor_quantifier_maybe($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, undef, $string, $re, $quantifier_maybe);
    }

    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# make_factor_symbol_quantifier_maybe
###############################################################################
sub make_factor_symbol_quantifier_maybe {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $symbol, $quantifier_maybe) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_factor_symbol_quantifier_maybe';
    $self->dumparg_in("$closure [symbol=$symbol, quantifier=" . (defined($quantifier_maybe) ? $quantifier_maybe : 'undef') . "]");

    my $rc = $self->make_factor_quantifier_maybe($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, undef, undef, $symbol, $quantifier_maybe);

    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# make_factor_quantifier_maybe
###############################################################################
sub make_factor_quantifier_maybe {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $action, $orig, $factor, $quantifier_maybe) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_factor_quantifier_maybe';
    $self->dumparg_in("$closure [action=" . (defined($action) ? $action : 'undef') . ", quantifier=" . (defined($quantifier_maybe) ? $quantifier_maybe : 'undef') . "]", $factor);

    my $rc;
    if (defined($quantifier_maybe) && $quantifier_maybe) {
	if (ref($factor) eq 'Regexp') {
	    #
	    ## Take care with the Regexp* or Regexp? !
	    ## This will be a full token, thus its size can be zero, and the recogniser does not like it.
	    ## Using the recognizer with a generated regexp will work only if it matches at least one
	    ## character
	    #
	    if ($self->is_star_quantifier($closure, $quantifier_maybe)) {
		#
		## Rule with min => 0 on the original regexp
		#
		$rc = $self->make_re($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, 0, $action, ${orig}, $factor);
	    } elsif ($self->is_plus_quantifier($closure, $quantifier_maybe)) {
		#
		## We guarantee that the same regexp without '+' will not reuse the rule by
		## overwriting the "origin" with the quantifier
		## Pa
		#
		$rc = $self->make_re($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, undef, $action, $orig, $factor);
	    } elsif ($self->is_questionmark_quantifier($closure, $quantifier_maybe)) {
		#
		## We have to concat it with an empty rule
		#
		my $lhs = $self->make_re($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, undef, $action, ${orig}, $factor);
		$rc = $self->make_maybe($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $action, $lhs);
	    } else {
		#
		## This must be digits
		#
		if (! ($quantifier_maybe =~ $TOKENS{DIGITS}->{re})) {
		    croak "Not a digit number: $quantifier_maybe\n";
		}
		my $digits = int($quantifier_maybe);
		if ($digits <= 0) {
		    croak "Invalid digit number: $digits\n";
		}
		my $neworig = "${digits}*${orig}";
		my $newfactor = qr/${factor}{$digits}/;
		$rc = $self->make_re($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, undef, $action, $neworig, $newfactor);
	    }
	} else {
	    my @rhs = ref($factor) eq 'ARRAY' ? @{${factor}} : ( ${factor} );
	    if ($self->is_star_quantifier($closure, $quantifier_maybe)) {
		$rc = $self->make_concat($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, 0, $action, @rhs);
	    } elsif ($self->is_plus_quantifier($closure, $quantifier_maybe)) {
		$rc = $self->make_concat($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, 1, $action, @rhs);
	    } elsif ($self->is_questionmark_quantifier($closure, $quantifier_maybe)) {
		$rc = $self->make_maybe($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $action, @rhs);
	    } else {
		#
		## This must be digits
		#
		if (! ($quantifier_maybe =~ $TOKENS{DIGITS}->{re})) {
		    croak "Not a digit number: $quantifier_maybe\n";
		}
		my $digits = int($quantifier_maybe);
		if ($digits <= 0) {
		    croak "Invalid digit number: $digits\n";
		}
		#
		## we really duplicate factor as many times driven by digits
		#
		$rc = $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, {rhs => [ (($factor) x $digits) ], action => $action});
	    }
	}
    } else {
	if (ref($factor) eq 'Regexp') {
	    $rc = $self->make_re($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, undef, $action, $orig, $factor);
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
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $lhs, $action, @rhs) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_any';
    $self->dumparg_in("$closure [action=" . (defined($action) ? $action : 'undef') . ", lhs=" . (defined($lhs) ? $lhs : 'undef') . "]", @rhs);

    #
    ## If:
    ## - there is a single rhs
    ## - we are not forced to generate an lhs
    ##
    ## then we are asked for an LHS that is strictly equivalent to the single RHS
    #
    my @okrhs = grep {defined($_)} @rhs;
    my $rc = $lhs;
    if ($#okrhs == 0) {
	$rc = $okrhs[0];
    } else {
	foreach (@okrhs) {
	    $rc = $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, {lhs => $rc, rhs => [ $_ ], action => $action});
	}
    }
    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# make_maybe
###############################################################################
sub make_maybe {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $action, $factor) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_maybe';

    $self->dumparg_in("$closure [action=" . (defined($action) ? $action : 'undef') . "]", $factor);

    my $rc = $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, {rhs => [ $factor ], action => $action});
    $rc = $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, {lhs => $rc, rhs => [ qw// ], action => $action});

    $self->dumparg_out($closure, $rc);
    return $rc;
}

###############################################################################
# make_re
###############################################################################
sub make_re {
    my ($self, $closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $min, $action, $orig, $re) = @_;

    $closure =~ s/\w+/  /;
    $closure .= 'make_re';
    $self->dumparg_in("$closure [min=" . (defined($min) ? $min : 'undef') . ", action=" . (defined($action) ? $action : 'undef') . "]", $orig, $re);

    my $rc = $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, {orig => $orig, re => $re, min => $min, action => $action});

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

    ${$quoted_stringp} =~ s/$re/my $m1 = substr(${$quoted_stringp}, $-[1], $+[1] - $-[1]) || ''; my $m2 = substr(${$quoted_stringp}, $-[2], $+[2] - $-[2]); if (exists($hashp->{$m2}) && (length($m1) % 4) == 0) {$m1 . $hashp->{$m2}} else {$m1 . $m2}/eg;

    my $rc = ${$quoted_stringp};
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
	    Marpa::R2::Context::bail("Cannot eval $match, $@");
	}
	$rc = qr/$re/;
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
    my $char_class_re = qr/([\\]*?)($char_class_concat)/;

    return $char_class_re;
}

###############################################################################
# make_rule
###############################################################################
sub make_rule {
    my $self = shift;
    my ($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, $symbol, $expressionp) = @_;

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
	$self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, {lhs => $symbol, rhs => []});
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
	    my $others = ($i == $#groups) ? $symbol . '_0' : $symbol . '_' . ($i + 1);
	    if ($#groups > 0) {
		if ($i == 0) {
		    #
		    ## symbol  ::= symbol(0)
		    ## ^^^^^^      ^^^^^^^^^
		    #
		    $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, {lhs => $symbol, rhs => [ $symboli ], action => $ACTION_FIRST_ARG});
		}
		if ($i < $#groups) {
		    #
		    ## symbol(n) ::= symbol(n+1) | groups(n)
		    ## ^^^^^^^^^     ^^^^^^^^^^^
		    #
		    $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, {lhs => $symboli, rhs => [ $others ], action => $ACTION_FIRST_ARG});
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
			    $after = $others;
			} elsif ($assoc eq 'right') {
			    $current_replacement = $others;
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
			$self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, {lhs => $symboli_group, rhs => [ @newrhs ], %{$hintsp}});
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
		    $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, {lhs => $symbol, rhs => [ @rhs ], %{$hintsp}});
		} else {
		    $self->add_rule($closure, $rulesp, $nb_lhs_generatedp, $tokensp, $nb_token_generatedp, {lhs => $symboli, rhs => [ @rhs ], %{$hintsp}});
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
# grammar
###############################################################################
sub grammar {
    my ($self, $string) = @_;

    my %lhs = ();
    my %rhs = ();
    my %tokens = ();
    my %rules = ();
    my @allrules = ();
    my $nb_lhs_generated = 0;
    my $nb_token_generated = 0;
    my $space_re = $self->space_re;
    my $eof_re = $self->eof_re;
    my %char_class = (%CHAR_CLASS,
		      quotemeta("\${space_re}") => ${space_re},
		      quotemeta("\${eof_re}") => ${eof_re});
    my $char_class_re = $self->char_class_re(\%char_class);
    my $word_boundary = $self->word_boundary;
    my $auto_rank = $self->auto_rank;

    #
    ## We rely on high_rule_only to resolve some ambiguity and do not want user to change that
    ## We want the default action to be $ACTION_ARGS in this stage
    #
    my $hashp = MarpaX::Import::Grammar->new({grammarp => $GRAMMAR, tokensp => \%TOKENS, hooksp => undef});
    my $multiple_parse_values = $self->multiple_parse_values;
    $self->multiple_parse_values(0);

    #
    ## In this array, we will put all strings that are not an lhs: then these are terminals
    #
    my %potential_token = ();

    #
    ## All actions have in common these arguments
    #
    my @COMMON_ARGS = (\%rules, \$nb_lhs_generated, \%tokens, \$nb_token_generated);

    #
    ## We want persistency between startrule concerning the scratchpad, so we use our own
    #
    my %scratchpad = ();

    #
    ## We prepare internal hashes to ease the dump in case of
    ## detection of multiple parse trees
    #
    $self->{generated_token} = {};
    $self->{generated_lhs} = {};

    $self->recognize($hashp,
		     $string,
		     {
			 _action_prolog_any => sub {
			     shift;
			     my $action = '_action_prolog_any';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my $rc = '';
			     $rc = $self->make_symbol($action, $rc);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_symbol => sub {
			     shift;
			     my $action = '_action_symbol';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my $rc = shift;
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_word => sub {
			     shift;
			     #
			     ## Formally exactly the same code as _action_symbol_balanced
			     ## except with ++$potential_token{$rc}
			     #
			     my $action = '_action_word';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my $rc = shift;
			     ++$potential_token{$rc};
			     $rc = $self->make_symbol($action, $rc);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_symbol_balanced => sub {
			     shift;
			     my $action = '_action_symbol_balanced';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my $rc = shift;
			     substr($rc, $[, 1, '');
			     substr($rc, $[ - 1, 1) = '';
			     $rc = $self->make_symbol($action, $rc);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			_action_factor_lbracket_lcurly_expression_rcurly_plus_rbracket => sub {
			     shift;
			     my $action = '_action_factor_lbracket_lcurly_expression_rcurly_plus_rbracket';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my (undef, undef, $expressionp, undef, undef, undef) = @_;
			     #
			     ## We make a rule out of this expression
			     #
			     my $lhs = $self->make_rule($action, @COMMON_ARGS, undef, $expressionp);
			     #
			     ## And we quantify it
			     #
			     my $rc = $self->make_factor_quantifier_maybe($action, @COMMON_ARGS, undef, undef, $lhs, '*');
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_lbracket_symbol_plus_rbracket => sub {
			     shift;
			     my $action = '_action_factor_lbracket_symbol_plus_rbracket';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my (undef, $symbol, undef, undef) = @_;
			     my $rc = $self->make_factor_quantifier_maybe($action, @COMMON_ARGS, undef, undef, $symbol, '*');
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_digits_star_lbracket_symbol_rbracket => sub {
			     shift;
			     my $action = '_action_factor_digits_star_lbracket_symbol_rbracket';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($digits, undef, undef, $symbol, undef) = @_;
			     #
			     ## We make a rule out of [ symbol ]
			     #
			     my $tmp = $self->make_factor_quantifier_maybe($action, @COMMON_ARGS, $ACTION_FIRST_ARG, $symbol, $symbol, '?');
			     #
			     ## And we add the digits quantifier
			     #
			     my $rc = $self->make_factor_quantifier_maybe($action, @COMMON_ARGS, undef, undef, $tmp, $digits);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_digits_star_lcurly_symbol_rcurly => sub {
			     shift;
			     my $action = '_action_factor_digits_star_lcurly_symbol_rcurly';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($digits, undef, undef, $symbol, undef) = @_;
			     my $rc = $self->make_factor_quantifier_maybe($action, @COMMON_ARGS, undef, undef, $symbol, $digits);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_symbol_balanced_quantifier_maybe => sub {
			     shift;
			     my $action = '_action_factor_symbol_balanced_quantifier_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($symbol, $quantifier_maybe) = @_;
			     my $rc = $self->make_factor_symbol_quantifier_maybe($action, @COMMON_ARGS, $symbol, $quantifier_maybe);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_word_quantifier_maybe => sub {
			     shift;
			     #
			     ## Formally exactly the same code as _action_factor_symbol_balanced_quantifier_maybe_balanced
			     ## except with ++$potential_token{$word}
			     #
			     my $action = '_action_factor_word_quantifier_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($word, $quantifier_maybe) = @_;
			     ++$potential_token{$word};
			     my $rc = $self->make_factor_symbol_quantifier_maybe($action, @COMMON_ARGS, $word, $quantifier_maybe);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_digits_star_symbol_balanced => sub {
			     shift;
			     my $action = '_action_factor_digits_star_symbol_balanced';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($digits, $star, $symbol) = @_;
			     my $rc = $self->make_factor_symbol_quantifier_maybe($action, @COMMON_ARGS, $symbol, $digits);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_digits_star_word => sub {
			     shift;
			     #
			     ## Formally exactly the same code as _action_factor_digits_star_symbol_balanced
			     ## except with ++$potential_token{$word}
			     #
			     my $action = '_action_factor_digits_star_word';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($digits, $star, $word) = @_;
			     ++$potential_token{$word};
			     my $rc = $self->make_factor_symbol_quantifier_maybe($action, @COMMON_ARGS, $word, $digits);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_expression_maybe => sub {
			     shift;
			     my $action = '_action_factor_expression_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my (undef, $expressionp, undef) = @_;
			     my $rc = $self->make_factor_expression_quantifier_maybe($action, @COMMON_ARGS, $expressionp, '?');
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_digits_star_expression => sub {
			     shift;
			     my $action = '_action_factor_digits_star_expression';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($digits, $star, $expressionp) = @_;
			     my $rc = $self->make_factor_expression_quantifier_maybe($action, @COMMON_ARGS, $expressionp, $digits);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_expression_quantifier_maybe => sub {
			     shift;
			     my $action = '_action_factor_expression_quantifier_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my (undef, $expressionp, undef, $quantifier_maybe) = @_;
			     my $rc = $self->make_factor_expression_quantifier_maybe($action, @COMMON_ARGS, $expressionp, $quantifier_maybe);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_string_quantifier_maybe => sub {
			     shift;
			     my $action = '_action_factor_string_quantifier_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($string, $quantifier_maybe) = @_;
			     my $rc = $self->make_factor_string_quantifier_maybe($action, @COMMON_ARGS, $string, $quantifier_maybe);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_digits_star_string => sub {
			     shift;
			     my $action = '_action_factor_digits_star_string';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($digits, $star, $string) = @_;
			     my $rc = $self->make_factor_string_quantifier_maybe($action, @COMMON_ARGS, $string, $digits);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_regexp => sub {
			     shift;
			     my $action = '_action_factor_regexp';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($string) = @_;
			     my $regexp = $string;
			     substr($regexp, $[, 1) = '';
			     substr($regexp, $[ - 1, 1) = '';
			     if ($self->regexp_common) {
				 $regexp = $self->handle_regexp_common($action, $regexp);
			     }
			     my $re = qr/\G${space_re}($regexp)/;
			     my $rc = $self->make_re($action, @COMMON_ARGS, undef, undef, $string, $re);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_char_range_quantifier_maybe => sub {
			     shift;
			     my $action = '_action_factor_char_range_quantifier_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($char_range, $quantifier_maybe) = @_;
			     my $rc = $self->make_factor_char_range_quantifier_maybe($action, @COMMON_ARGS, $char_range, 'CHAR_RANGE', $quantifier_maybe);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_digits_star_char_range => sub {
			     shift;
			     my $action = '_action_factor_digits_star_char_range';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($digits, $char_range) = @_;
			     my $rc = $self->make_factor_char_range_quantifier_maybe($action, @COMMON_ARGS, $char_range, 'CHAR_RANGE', $digits);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_caret_char_range_quantifier_maybe => sub {
			     shift;
			     my $action = '_action_factor_caret_char_range_quantifier_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($caret_char_range, $quantifier_maybe) = @_;
			     my $rc = $self->make_factor_char_range_quantifier_maybe($action, @COMMON_ARGS, $caret_char_range, 'CARET_CHAR_RANGE', $quantifier_maybe);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_digits_star_caret_char_range => sub {
			     shift;
			     my $action = '_action_factor_digits_star_caret_char_range';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($caret_char_range, $quantifier_maybe) = @_;
			     my $rc = $self->make_factor_char_range_quantifier_maybe($action, @COMMON_ARGS, $caret_char_range, 'CARET_CHAR_RANGE', $quantifier_maybe);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_factor_hexchar_many_quantifier_maybe => sub {
			     shift;
			     my $action = '_action_factor_hexchar_many_quantifier_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($hexchar_many, $quantifier_maybe) = @_;
			     my $rc = $self->make_factor_quantifier_maybe($action, @COMMON_ARGS, undef, undef, $hexchar_many, $quantifier_maybe);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_hexchar_many => sub {
			     shift;
			     my $action = '_action_hexchar_many';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my (@hexchar) = @_;
			     my $rc = $self->make_concat($action, @COMMON_ARGS,
							 undef,
							 undef,
							 map
							 {
							     my $orig = $_;
							     $orig =~ $TOKENS{HEXCHAR}->{re};
							     my $r = '\\x{' . substr($orig, $-[2], $+[2] - $-[2]) . '}';
							     my $re = qr/\G${space_re}(${r})/;
							     $self->make_re($action, @COMMON_ARGS, undef, undef, $orig, $re);
							 } @hexchar);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_quantifier => sub {
			     shift;
			     my $action = '_action_quantifier';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($quantifier) = @_;
			     my $rc = $quantifier;
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_quantifier_maybe => sub {
			     shift;
			     my $action = '_action_quantifier_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($quantifier) = @_;
			     my $rc = $quantifier;
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_comma_maybe => sub {
			     shift;
			     my $action = '_action_comma_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($comma) = @_;
			     my $rc = $comma;
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_term => sub {
			     shift;
			     my $action = '_action_term';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($factor) = @_;
			     my $rc = $factor;
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_more_term_maybe => sub {
			     shift;
			     my $action = '_action_more_term_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($more_term) = @_;
			     my $rc = $more_term;
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_more_term => sub {
			     shift;
			     my $action = '_action_more_term';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my (undef, $term) = @_;
			     my $rc = $term;
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_exception => sub {
			     shift;
			     my $action = '_action_exception';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
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
				 # my $lhs1 = $self->add_rule($action, @COMMON_ARGS, {rhs => [ $term1 ]});
				 # my $lhs2 = $self->add_rule($action, @COMMON_ARGS, {action => $self->action_failure, rhs => [ $term2 ]});
				 # my $lhs = $self->make_any($action, @COMMON_ARGS, undef, undef, $lhs2, $lhs1);
                                 my $lhs = $self->make_rule($action, @COMMON_ARGS, undef,
                                                            [
                                                             [ undef,  [ [ $term2 ] ], { rank => 1, action => $self->action_failure } ],
                                                             [
                                                              [  '|',  [ [ $term1 ] ], { rank => 0, action => $ACTION_FIRST_ARG } ],
                                                             ]
                                                            ]
                                                           );

				 $rc = [ $lhs ];
			     }
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_exception_any => sub {
			     shift;
			     my $action = '_action_exception_any';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my $rc = [ @_ ];
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_exception_many => sub {
			     shift;
			     my $action = '_action_exception_many';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my $rc = [ @_ ];
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_hint_rank => sub {
			     shift;
			     my $action = '_action_hint_rank';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($rank) = @_;
			     if (defined($rank) && $auto_rank) {
				 croak "rank => $rank is incompatible with option auto_rank\n";
			     }
			     my $rc = {rank => $rank};
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_hint_action => sub {
			     shift;
			     my $action = '_action_hint_action';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($thisaction) = @_;
			     my $rc = {action => $thisaction};
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_hint_assoc => sub {
			     shift;
			     my $action = '_action_hint_assoc';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($assoc) = @_;
			     my $rc = {assoc => $assoc};
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 #
			 ## This rule merges all hints into a single return value
			 #
			 _action_hint_any => sub {
			     shift;
			     my $action = '_action_hint_any';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my (@hints) = @_;
			     my $rc = {};
			     foreach (@hints) {
				 my $hint = $_;
				 foreach (qw/action assoc rank/) {
				     if (exists($hint->{$_})) {
					 if (exists($rc->{$_})) {
					     croak "$_ is defined twice: $rc->{$_}, $hint->{$_}\n";
					 }
					 $rc->{$_} = $hint->{$_};
				     }
				 }
			     }
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_hints_maybe => sub {
			     shift;
			     my $action = '_action_hints_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($hint) = @_;
			     my $rc = $hint;
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_comment => sub {
			     shift;
			     $self->dumparg('==> _action_comment', @_);
			     my $rc = undef;
			     $self->dumparg('<== _action_comment', $rc);
			     return $rc;
			 },
			 _action_ignore => sub {
			     shift;
			     $self->dumparg('==> _action_ignore', @_);
			     my $rc = undef;
			     $self->dumparg('<== _action_ignore', $rc);
			     return $rc;
			 },
			 _action_dumb => sub {
			     shift;
			     $self->dumparg('==> _action_dumb', @_);
			     my $rc = undef;
			     $self->dumparg('<== _action_dumb', $rc);
			     return $rc;
			 },
			 _action_concatenation => sub {
			     shift;
			     my $action = '_action_concatenation';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($exception_any, $hints_maybe, $dumb_any) = @_;
			     #
			     ## The very first concatenation is marked with undef instead of PIPE
			     #
			     my $rc = [ undef, $exception_any, $hints_maybe || {} ];
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_concatenation_hints_maybe => sub {
			     shift;
			     my $action = '_action_concatenation_hint_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($hints_maybe, $dumb_any) = @_;
			     #
			     ## The very first concatenation is marked with undef instead of PIPE
			     #
			     my $rc = [ undef, [], $hints_maybe || {} ];
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_more_concatenation_any => sub {
			     shift;
			     my $action = '_action_more_concatenation_any';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my $rc = [ @_ ];
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_more_concatenation => sub {
			     shift;
			     my $action = '_action_more_concatenation';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
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
			     my $rc = $concatenation;
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_expression => sub {
			     shift;
			     my $action = '_action_expression';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my $rc = [ @_ ];
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_rule => sub {
			     shift;
			     my $action = '_action_rule';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my (undef, $symbol, undef, $expressionp, undef, undef) = @_;
			     my $rc = $self->make_rule($action, @COMMON_ARGS, $symbol, $expressionp);
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_more_rule => sub {
			     shift;
			     my $action = '_action_more_rule';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my (undef, $rule) = @_;
			     my $rc = $rule;
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_rule_any => sub {
			     shift;
			     my $action = '_action_rule_any';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my (@more_rule) = @_;
			     push(@allrules, @more_rule);
			     my $rc = undef;
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_more_rule_any => sub {
			     shift;
			     $self->dumparg('==> _action_more_rule_any', @_);
			     my (@more_rule) = @_;
			     push(@allrules, @more_rule);
			     my $rc = undef;
			     $self->dumparg('<== _action_more_rule_any', $rc);
			     return $rc;
			 },
			 _action_eol_any => sub {
			     shift;
			     my $action = '_action_eol_any';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my $rc = undef;
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_spaces_maybe => sub {
			     shift;
			     my $action = '_action_spaces_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my $rc = undef;
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_rulenumber_maybe => sub {
			     shift;
			     my $action = '_action_rulenumber_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my $rc = undef;
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_ruleend_maybe => sub {
			     shift;
			     my $action = '_action_ruleend_maybe';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 0, $action, @_);
			     $self->dumparg_in($action, @_);
			     my $rc = undef;
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 },
			 _action_startrule => sub {
			     shift;
			     my $action = '_action_startrule';
			     my $scratchpad = \%scratchpad;
			     $self->action_push(@COMMON_ARGS, $scratchpad, 1, $action, @_);
			     $self->dumparg_in($action, @_);
			     my ($space_any, @terms) = @_;
			     push(@allrules, $terms[0]);
			     my $rc = $terms[0];
			     $self->dumparg_out($action, $rc);
			     $self->action_pop($scratchpad, $rc);
			     return $rc;
			 }
		     }
	)
	||
	croak "Recognizer error";

    #
    ## We create all terminals that were not done automatically because the writer decided
    ## to write lhs not using <>
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
	## This really is terminal, we create the corresponding token
	#
	my $quoted = quotemeta($token);
	my $boundary = ($word_boundary && ($token =~ /^[[:word:]]+$/)) ? '\\b' : '';
	my $re = qr/\G${space_re}(${quoted})${boundary}/;
	$self->make_token_if_not_exist('grammar', \%tokens, \$nb_token_generated, $token, $token, $re, '');
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
	$start = $self->make_any('____start____', @COMMON_ARGS, undef, undef, @{$self->startrules});
    } else {
	$start = $self->startrules->[0];
    }

    if ($self->log_debug) {
	$log->debugf('Ranking method: %s', 'high_rule_only');
	$log->debugf('Default action: %s', $ACTION_ARGS);                         # No choice
	$log->debugf('Multiple parse values: %d', $multiple_parse_values);
	$log->debugf('Start rule: %s', $start);
    }
    my @rules = ();
    foreach (sort keys %rules) {
	foreach (@{$rules{$_}}) {
	    my $min    = (exists($_->{min})    && defined($_->{min}))    ? $_->{min}    : undef;
	    my $rank   = (exists($_->{rank})   && defined($_->{rank}))   ? $_->{rank}   : undef;
	    my $action = (exists($_->{action}) && defined($_->{action})) ? $_->{action} : undef;
	    if ($self->log_debug) {
		$log->debugf('Grammar rule: {lhs => \'%s\', rhs => [\'%s\'], min => %s, action => %s, rank => %s',
                             $_->{lhs},
                             join("', '", @{$_->{rhs}}),
                             defined($min) ? $min : 'undef',
                             defined($action) ? $action : 'undef',
                             defined($rank) ? $rank : 'undef');
	    }
	    push(@rules, {lhs => $_->{lhs}, rhs => [@{$_->{rhs}}], min => $min, action => $action, rank => $rank});
	}
    }

    if ($self->debug) {
	foreach (sort keys %tokens) {
	    if ($self->log_debug) {
		$log->debugf('Token %s: orig=%s, re=%s, code=%s',
                             $_,
                             (exists($tokens{$_}->{orig}) && defined($tokens{$_}->{orig}) ? $tokens{$_}->{orig} : ''),
                             (exists($tokens{$_}->{re})   && defined($tokens{$_}->{re})   ? $tokens{$_}->{re}   : ''),
                             (exists($tokens{$_}->{code}) && defined($tokens{$_}->{code}) ? $tokens{$_}->{code} : ''));
	    }
	}
    }

    my %grammar = (
	start                => $start,
	default_action       => $ACTION_ARGS,
	infinite_action      => $self->infinite_action,
	trace_file_handle    => $MARPA_TRACE_FILE_HANDLE,
	terminals            => [keys %tokens],
	rules                => \@rules
	);

    my $grammar = Marpa::R2::Grammar->new(\%grammar);

    $grammar->precompute();

    #
    ## Restore things that we eventually overwrote
    #
    $self->multiple_parse_values($multiple_parse_values);

    #
    ## We return a single hash that gives:
    ## - the grammar
    ## - the tokens
    ## - the code hooks
    #

    return MarpaX::Import::Grammar->new({grammarp => $grammar, rulesp => \@rules, tokensp => \%tokens, hooksp => undef});
}

###############################################################################
# lexer
###############################################################################
sub lexer {
    my ($self, $stringp, $tokensp, $pos, $expected, $closuresp) = @_;
    my @matches = ();

    foreach (@{$expected}) {
	my $code = $tokensp->{$_}->{code};
	if (! defined($code) || ! $code) {
	    $log->errorf("Missing definition for token %s", $_);
	} else {
	    my $coderc = &$code($self, $stringp, $tokensp, $pos, $_, $closuresp);
	    if (defined($coderc)) {
		push(@matches, $coderc);
	    }
	}
    }

    return @matches;
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
# word_boundary
###############################################################################
sub word_boundary {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('word_boundary', '', @_);
	$self->{word_boundary} = shift;
    }
    return $self->{word_boundary};
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
# eof_aware
###############################################################################
sub eof_aware {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('eof_aware', '', @_);
	$self->{eof_aware} = shift;
    }
    return $self->{eof_aware};
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
# eof_re
###############################################################################
sub eof_re {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('eof_re', 'Regexp', @_);
	$self->{eof_re} = shift;
    }
    return $self->{eof_re};
}

###############################################################################
# startrules
###############################################################################
sub startrules {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('start', 'ARRAY', @_);
	$self->{startrules} = shift;
    }
    return $self->{startrules};
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
# debug
###############################################################################
sub debug {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('debug', '', @_);
	$self->{debug} = shift;
    }
    return $self->{debug};
}

###############################################################################
# lex_re_m_modifier
###############################################################################
sub lex_re_m_modifier {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('lex_re_m_modifier', '', @_);
	$self->{lex_re_m_modifier} = shift;
    }
    return $self->{lex_re_m_modifier};
}

###############################################################################
# lex_re_s_modifier
###############################################################################
sub lex_re_s_modifier {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('lex_re_s_modifier', '', @_);
	$self->{lex_re_s_modifier} = shift;
    }
    return $self->{lex_re_s_modifier};
}

###############################################################################
# space_re
###############################################################################
sub space_re {
    my $self = shift;
    if (@_) {
	$self->option_value_is_ok('space_re', 'Regexp', @_);
	$self->{space_re} = shift;
    }
    return $self->{space_re};
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
# action_two_args_recursive
###############################################################################
sub action_two_args_recursive {
    my $scratchpad = shift;

    # __PACKAGE__->_dumparg("==> action_two_args_recursive ", @_);

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
	    my $grammar = $Marpa::R2::Context::grammar;
	    my $what = '';
	    my $lhs = '';
	    my @rhs = ();
	    if (defined($rule_id) && defined($grammar)) {
		my ($lhs, @rhs) = $grammar->rule($rule_id);
		$what = sprintf(', %s ::= %s ', $lhs, join(' ', @rhs));
	    }
	    $log->tracef("Hit in recursive rule without a hit on the single item%s", $what);
	    $log->tracef("Values of the rhs: %s", \@_);
	    Marpa::R2::Context::bail('Hit in recursive rule without a hit on the single item');
	}
	if ($scratchpad->{action_two_args_recursive_count} == 1) {
	    $rc = [ $_[0]->[0], $_[1]->[0] ];
	    ++$scratchpad->{action_two_args_recursive_count};
	} else {
	    $rc = [ @{$_[0]}, $_[1]->[0] ];
	}
    }

    # __PACKAGE__->_dumparg("<== action_two_args_recursive ", $rc);

    return $rc;
}

###############################################################################
# action_make_arrayp
###############################################################################
sub action_make_arrayp {
    shift;
    # __PACKAGE__->_dumparg("==> action_make_arrayp ", @_);
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
      print STDERR "\$_[0] is $_[0]\n";
      if (! ref($_[0])) {
	$rc = [ @_ ];
      } else {
	$rc = $_[0];
      }
    }
    # __PACKAGE__->_dumparg("<== action_make_arrayp ", $rc);
    return $rc;
}

###############################################################################
# action_empty
###############################################################################
sub action_empty {
    shift;
    # __PACKAGE__->_dumparg("==> action_empty ", @_);
    my $rc = [ ];
    # __PACKAGE__->_dumparg("==> action_empty ", $rc);
    return $rc;
}

###############################################################################
# action_args
###############################################################################
sub action_args {
    shift;
    # __PACKAGE__->_dumparg("==> action_args ", @_);
    my $rc = [ @_ ];
    # __PACKAGE__->_dumparg("<== action_args ", $rc);
    return $rc;
}

###############################################################################
# action_first_arg
###############################################################################
sub action_first_arg {
    shift;
    # __PACKAGE__->_dumparg("==> action_first_arg ", @_);
    my $rc = $_[0];
    # __PACKAGE__->_dumparg("<== action_first_arg ", $rc);
    return $rc;
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
    my $hooksp = $hashp->hooksp;

    my $pos_max = length($string) - 1;

    #
    ## We add to closures our internal action for exception handling
    #
    my $okclosuresp = $closuresp || {};

    #
    ## Handle the exceptions
    #
    my $exception = 0;
    $okclosuresp->{$self->action_failure} = sub {
	shift;
        #
        # my ( $lhs, @rhs ) = $grammarp->rule($Marpa::R2::Context::rule);
        # $log->tracef("Exception in rule: %s ::= %s", $lhs, join(' ', @rhs));
        # $log->tracef("Values of the rhs: %s", \@_);
        # Marpa::R2::Context::bail('Exception');
	$exception = 1;
    };

    #
    ## Comments are not part of the grammar
    ## We remove them, taking into account newlines
    ## The --hr, --li, --## have to be in THIS regexp because of the ^ anchor, that is not propagated
    ## if it would be in $WEBCODE_RE
    #
    $string =~ s#^[^\n]*\-\-(?:hr|li|\#\#)[^\n]*|$WEBCODE_RE#my ($start, $end, $length) = ($-[0], $+[0], $+[0] - $-[0]); my $comment = substr($string, $start, $length); my $nbnewline = ($comment =~ tr/\n//); substr($string, $start, $length) = (' 'x ($length - $nbnewline)) . ("\n" x $nbnewline);#esmg;

    if ($self->log_debug) {
	$log->debugf('trace_terminals => %s', $self->trace_terminals);
	$log->debugf('trace_values    => %s', $self->trace_values);
        $log->debugf('trace_actions   => %s', $self->trace_actions);
    }

    my $rec = Marpa::R2::Recognizer->new
	(
	 {
	     grammar => $grammarp,
	     ranking_method => 'high_rule_only',
	     trace_file_handle => $MARPA_TRACE_FILE_HANDLE,
	     trace_terminals => $self->trace_terminals,
	     trace_values => $self->trace_values,
	     trace_actions => $self->trace_actions,
	     closures => $okclosuresp
	 }
	);

    my ($prev, $linenb, $colnb, $line) = (undef, 1, 0, '');

    my $eof_re = $self->eof_re;
    my $pos;
    foreach (0..$pos_max) {
	$pos = $_;
	my $c = substr($string, $pos, 1);
	#
	## Get out automatically if this is end of the input
	#
	if ($self->eof_aware) {
	    pos($string) = $pos;
	    if ($string =~ m/$eof_re/g) {
		if ($self->log_debug) {
		    $log->debug("EOF detected");
		}
		last;
	    }
	}

	if (defined($prev) && $prev eq "\n") {
	    $colnb = 0;
	    $line = '';
	    ++$linenb;
	}

	++$colnb;
	$prev = $c;
	$line .= $prev;

	my @matching_tokens = ();
	my $expected_tokens = $rec->terminals_expected;
        if ($self->log_debug) {
	    $self->show_line(0, $linenb, $colnb, $pos, $pos_max, $line, $colnb);
	    #foreach (split(/\n/, $rec->show_progress)) {
	    #  $log->debug($_);
	    #}
        }
	if (@{$expected_tokens}) {
	    if ($self->log_debug) {
		foreach (sort @{$expected_tokens}) {
		    $log->debugf('%sExpected %s: orig=%s, re=%s',
                                 $self->position_trace($linenb, $colnb, $pos, $pos_max),
                                 $_,
                                 ((exists($tokensp->{$_}->{orig}) && defined($tokensp->{$_}->{orig})) ? $tokensp->{$_}->{orig} : ''),
                                 ((exists($tokensp->{$_}->{re})   && defined($tokensp->{$_}->{re})    ? $tokensp->{$_}->{re}   : '')));
		}
	    }
	    @matching_tokens = $self->lexer(\$string, $tokensp, $pos, $expected_tokens, $closuresp);

	    if ($self->log_debug) {
		foreach (sort @matching_tokens) {
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
	    last
	}
    }

    if ($self->debug) {
	pos($string) = $pos;
	if ($string =~ m/$eof_re/g) {
          $log->debugf('End of input at position [%s/%s]', $pos, $pos_max);
	} else {
          $log->debugf('Parsing stopped at position [%s/%s]', $pos, $pos_max);
	}
    }
    $rec->end_input;

    #
    ## Evaluate all parse tree results
    #
    my @value = ();
    my $value_ref = undef;
    my $nbparsing_with_exception = 0;
    do {
	$exception = 0;
	$value_ref = $rec->value || undef;
	if (defined($value_ref) && $exception == 0) {
	    push(@value, ${$value_ref});
	}
	if ($exception != 0) {
	    ++$nbparsing_with_exception;
	}
    } while (defined($value_ref));

    if (! @value) {
	if ($nbparsing_with_exception == 0) {
          $log->error('No parsing');
	} else {
          $log->errorf('%d parse tree%s raised exception with unwanted term', $nbparsing_with_exception, ($nbparsing_with_exception > 1) ? 's' : '');
	}
      } else {
	if ($self->debug) {
	    foreach (0..$#value) {
		$log->debugf("[%d/%2d] Parse tree value: %s", $_, $#value, $value[$_]);
	    }
	}
        if (! $self->multiple_parse_values && $#value > 0) {
	    die scalar(@value) . " parse values but multiple_parse_values setting is off\n";
        }
    }

    my $rc = wantarray ? @value : shift(@value);

    return $rc;
}

###############################################################################
# show_line
###############################################################################
sub show_line {
    my ($self, $errormodeb, $linenb, $col, $pos, $pos_max, $line, $colnb) = @_;

    my $position_trace = $self->position_trace($linenb, $colnb, $pos, $pos_max);
    my $pointer = ($colnb > 0 ? '-' x ($colnb-1) : '') . '^';
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

=item * any concatenation can be followed by action => ..., rank => ..., assoc => ...

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

=item $import->space_re($)

Some grammars deals themselves with spaces. Like SQL and XML. In such a case you might want to have no automatic jump over what MarpaX::Import thinks is a "space". Input must be a regular expression. Default is qr/[[:space:]]*/.

=item $import->debug($)

MarpaX::Import is very verbose in debug mode, and that can be a performance penalty. This option controls the calls to tracing in debug mode. Input must be a scalar. Default is 0.

=item $import->char_escape($)

MarpaX::Import must know if perl's char escapes are implicit in strings or not. The perl char escapes themselves are \\a, \\b, \\e, \\f, \\n, \\r, \\t. Input must be a scalar. Default is 1.

=item $import->regexp_common($)

MarpaX::Import must know if Regexp::Common regular expressions can be part of regular expressions when importing a grammar. A regular expression in an imported grammar has the form /something/. Regexp::Common are suppported as: /$RE{something}{else}{and}{more}/. Input must be a scalar. Default is 1.

=item $import->char_class($)

MarpaX::Import must know if character classes are used in regular expressions. A character class has the form /[:someclass:]/. Input must be a scalar. Default is 1.

=item $import->trace_terminals($), $import->trace_values($), $import->trace_actions($), $import->infinite_action($), $import->ranking_method($)

These options are passed as-is to Marpa. Please note that the Marpa logging is redirected to Log::Any.

=item $import->startrules($)

User can give a list of rules that will be the startrule. Input must be a reference to an array. Default is [qw/startrule/].

=item $import->auto_rank($)

Rules can be auto-ranked, i.e. if this option is on every concatenation of a rule has a rank that is the previous rank minus 1. Start rank value is 0. Input must be a scalar. Default is 0. This leave to the read's intuition: what is the default ranking method when calling Marpa, then. It is 'high_rule_only' and this is fixed. If this option is on, then the use of rank => ... is forbiden in the grammar. Input must be a scalar. Default is 0.

=item $import->multiple_parse_values($)

Ambiguous grammars can give multiple parse tree values. If this option is set to false, then MarpaX::Import will bail, giving in its log the location of the divergence from actions point of view. Input must be a scalar. Default is 0.

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
