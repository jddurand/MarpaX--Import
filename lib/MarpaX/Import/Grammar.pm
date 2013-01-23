# *****************************************************************************
#
package MarpaX::Import::Grammar;
use strict;
use diagnostics;
use Log::Any qw/$log/;
use Carp;
#
# *****************************************************************************

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

    my $self = {
	recp     => $optp->{recp},
	grammarp => $optp->{grammarp},
	tokensp  => $optp->{tokensp},
	rulesp   => $optp->{rulesp},
    };

    bless($self, $class);

    return $self;
}

###############################################################################
# make_tokens_pos_aware
###############################################################################
sub make_tokens_pos_aware {
    my ($self, $space_re, $g0b) = @_;

    if ($g0b == 0) {
	#
	## This grammar is not G0 (i.e. lex) aware.
	## We revisit all tokens regexp: systematically add a pre rule that will affect position
	#
	foreach (keys %{$self->{tokensp}}) {
	    my $token = $_;
	    my $oldpre = $self->{tokensp}->{$token}->{pre} || undef;
	    $self->{tokensp}->{$token}->{space_re} = $space_re;
	    if (defined($oldpre)) {
		# $class = $_[0]
		# $stringp = $_[1]
		# $line = $_[2] !! Take care $line does contain only current character after \G
		# $tokensp = $_[3]
		# $pos = $_[4]
		# $posline = $_[5]
		# $linenb = $_[6]
		# $token_name = $_[7]
		# $inneroffset = $_[8]
		$self->{tokensp}->{$token}->{pre} = sub {
		    if ($_[1] =~ $_[3]->{$_[7]}->{space_re}) {
			$_[4] = $+[0];
			$_[8] += $+[0] - $-[0];
			pos($_[1]) = $_[4];
		    }
		    return &$oldpre(@_);
		};
	    } else {
		$self->{tokensp}->{$token}->{pre} = sub {
		    if ($_[1] =~ $_[3]->{$_[7]}->{space_re}) {
			$_[4] = $+[0];
			$_[8] += $+[0] - $-[0];
			pos($_[1]) = $_[4];
		    }
		    return 1;
		};
	    }
	}
    }

    return $self;
}

###############################################################################
# grammarp
###############################################################################
sub grammarp {
    my $self = shift;
    if (@_) {
	$self->{grammarp} = shift;
    }
    return $self->{grammarp};
}

###############################################################################
# recp
###############################################################################
sub recp {
    my $self = shift;
    if (@_) {
	$self->{recp} = shift;
    }
    return $self->{recp};
}

###############################################################################
# tokensp
###############################################################################
sub tokensp {
    my $self = shift;
    if (@_) {
	$self->{tokensp} = shift;
    }
    return $self->{tokensp};
}

###############################################################################
# rulesp
###############################################################################
sub rulesp {
    my $self = shift;
    if (@_) {
	$self->{rulesp} = shift;
    }
    return $self->{rulesp};
}

###############################################################################
# rules_as_string
###############################################################################
sub rules_as_string {
    my ($self, @wanted) = @_;

    my $rc = '';
    my @rc = ();
    my $previous_lhs = undef;
    foreach (@{$self->rulesp}) {
	my ($lhs,
	    $rhsp,
	    $min,
	    $action,
	    $rank,
	    $separator,
	    $proper) = ($_->{lhs},
			$_->{rhs},
			exists($_->{min})       ? $_->{min}       : undef,
			exists($_->{action})    ? $_->{action}    : undef,
			exists($_->{rank})      ? $_->{rank}      : undef,
			exists($_->{separator}) ? $_->{separator} : undef,
			exists($_->{proper})    ? $_->{proper}    : undef);
      if (@wanted && ! grep {$lhs eq $_} @wanted) {
        next;
      }
      my $first = "<$lhs>\t::=\t";
      if (defined($previous_lhs)) {
        if ($previous_lhs eq $lhs) {
          #
          ## This is a '|'
          #
          $first = sprintf("%s\t|\t", ' ' x (length($lhs) + 2));
        } else {
          #
          ## This is a new lhs
          #
          push(@rc, '');
        }
      }
      my $this = sprintf('%s%s', $first, join(' ',
					      map {
						  exists($self->tokensp->{$_}) ? (exists($self->tokensp->{$_}->{re}) ? "qr/$self->tokensp->{$_}->{re}/" : $self->tokensp->{$_}->{orig}) : '????'} @{$rhsp}));
						      
      if (defined($rank)) {
        $this .= sprintf(' rank=>%d', $rank);
      }
      if (defined($separator)) {
        $this .= sprintf(' separator=><%s>', $separator);
      }
      if (defined($proper)) {
        $this .= sprintf(' proper=>%d', $proper);
      }
      if (defined($min)) {
        $this .= sprintf(' min=>%d', $min);
      }
      if (defined($action)) {
        $this .= sprintf(' action=>\'%s\'', $action);
      }
      push(@rc, $this);
      $previous_lhs = $lhs;
    }

    $rc = join("\n", @rc, "\n");

    return $rc;
}

1;

__END__
=head1 NAME

MarpaX::Import::Grammar - Supported grammars described using itself

=head1 GRAMMAR

DIGITS			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*([[:digit:]]+)/

COMMA			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(,)/

RULESEP			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(::=|:|=)/

PIPE			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(\|{1,2})/

MINUS			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(\-)/

STAR			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(\*)/

PLUS			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(\+|\.\.\.)/

RULEEND			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(;|\.)/

QUESTIONMARK		::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(\?)/

STRING			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*($RE{delimited}{-delim=>q{'"}})/

WORD			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*([[:word:]]+)/

LBRACKET		::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(\[)/

RBRACKET		::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(\])/

LPAREN			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(\()/

RPAREN			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(\))/

LCURLY			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(\{)/

RCURLY			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(\})/

SYMBOL_BALANCED		::=	/\G[ \f\t\r]*\n?[ \f\t\r]*($RE_SYMBOL_BALANCED)/

HEXCHAR			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(#x([[:xdigit:]]+))/

CHAR_RANGE		::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(\[(#x[[:xdigit:]]+|[^\^][^[:cntrl:][:space:]]*?)(?:\-(#x[[:xdigit:]]+|[^[:cntrl:][:space:]]+?))?\])/

CARET_CHAR_RANGE	::=	/\G[ \f\t\r]*\n?[ \f\t\r]*(\[\^(#x[[:xdigit:]]+|[^[:cntrl:][:space:]]+?)(?:\-(#x[[:xdigit:]]+|[^[:cntrl:][:space:]]+?))?\])/

ACTION			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*action[ \f\t\r]*=>[ \f\t\r]*([[:alpha:]][[:word:]]*)/

RANK			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*rank[ \f\t\r]*=>[ \f\t\r]*(\-?[[:digit:]]+)/

ASSOC			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*assoc[ \f\t\r]*=>[ \f\t\r]*(left|group|right)/

SEPARATOR		::=	/\G[ \f\t\r]*\n?[ \f\t\r]*separator[ \f\t\r]*=>[ \f\t\r]*([[:alpha:]][[:word:]]*)/

PROPER			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*proper[ \f\t\r]*=>[ \f\t\r]*(0|1)/

RULENUMBER		::=	/\G[[:space:]]*(\[[[:digit:]][^\]]*\])/

REGEXP			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*($RE{delimited}{-delim=>q{\/}})/

SPACES			::=	/\G([[:space:]]+)/

EOL			::=	/\G([ \f\t\r]*\n)/

EOL_EOL_ETC		::=	/\G((?:[ \f\t\r]*\n){2,})/

IGNORE			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*($RE{balanced}{-begin => '[wfc|[WFC|[vc|[VC'}{-end => ']|]|]|]'})/

COMMENT			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*($RE{comment}{C})/

spaces_maybe		::= SPACES?

startrule		::= spaces_maybe rule more_rule_any

more_rule		::= EOL_EOL_ETC rule

more_rule_any		::= more_rule*

symbol_balanced		::= SYMBOL_BALANCED

word			::= WORD

symbol			::= symbol_balanced | word

rulenumber_maybe	::= RULENUMBER |

ruleend_maybe		::= RULEEND |

rule			::= rulenumber_maybe symbol RULESEP expression ruleend_maybe

expression		::= concatenation more_concatenation_any

expression_notempty	::= concatenation_notempty more_concatenation_any

hint			::= RANK | ACTION | ASSOC | SEPARATOR | PROPER

hint_any		::= hint*

hints_maybe		::= hint_any?

more_concatenation	::= PIPE concatenation

more_concatenation_any	::= more_concatenation*

dumb			::= IGNORE | COMMENT

dumb_any		::= dumb*

concatenation		::= exception_any hints_maybe dumb_any

concatenation_notempty	::= exception_many hints_maybe dumb_any

comma_maybe		::= COMMA?

exception_any		::= exception*

exception_many		::= exception+

exception		::= term more_term_maybe comma_maybe

more_term		::= MINUS term

more_term_maybe		::= more_term?

term			::= factor

quantifier		::= STAR | PLUS | QUESTIONMARK

quantifier_maybe	::= quantifier?

hexchar_many		::= HEXCHAR+

factor			::= LBRACKET LCURLY expression_notempty RCURLY PLUS RBRACKET rank => 4
			  | LBRACKET symbol PLUS RBRACKET                            rank => 4
			  | DIGITS STAR LBRACKET symbol RBRACKET                     rank => 4
			  | DIGITS STAR LCURLY symbol RCURLY                         rank => 4
			  | symbol_balanced quantifier                               rank => 4
			  | symbol_balanced                                          rank => 4
			  | DIGITS STAR symbol_balanced				     rank => 4
			  | STRING quantifier                                        rank => 3
			  | STRING                                                   rank => 3
			  | DIGITS STAR STRING                                       rank => 3
			  | CARET_CHAR_RANGE quantifier                              rank => 2
			  | CARET_CHAR_RANGE                                         rank => 2
			  | CHAR_RANGE quantifier                                    rank => 2
			  | CHAR_RANGE                                               rank => 2
			  | REGEXP                                                   rank => 1
			  | LPAREN expression_notempty RPAREN quantifier             rank => 1
			  | LPAREN expression_notempty RPAREN                        rank => 1
			  | LCURLY expression_notempty RCURLY quantifier             rank => 1
			  | LCURLY expression_notempty RCURLY                        rank => 1
			  | LBRACKET expression_notempty RBRACKET                    rank => 1
			  | DIGITS STAR expression_notempty                          rank => 1
			  | word quantifier                                          rank => 1
			  | word                                                     rank => 1
			  | DIGITS STAR word                                         rank => 1
			  | hexchar_many quantifier                                  rank => 1
			  | hexchar_many                                             rank => 0
