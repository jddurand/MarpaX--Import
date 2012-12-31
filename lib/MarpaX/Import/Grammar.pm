# *****************************************************************************
#
package MarpaX::Import::Grammar;
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
	grammarp => $optp->{grammarp},
	tokensp  => $optp->{tokensp},
	rulesp   => $optp->{rulesp},
	hooksp   => $optp->{hooksp}
    };

    bless($self, $class);

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
# hooksp
###############################################################################
sub hooksp {
    my $self = shift;
    if (@_) {
	$self->{hooksp} = shift;
    }
    return $self->{hooksp};
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
      my ($lhs, $rhsp, $min, $action, $rank) = ($_->{lhs}, $_->{rhs}, $_->{min}, $_->{action}, $_->{rank});
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
      my $this = sprintf('%s%s', $first, join(' ', map {exists($self->tokensp->{$_}) ? (defined($self->tokensp->{$_}->{orig}) ? ('\'' . $self->tokensp->{$_}->{orig} . '\'') : ('/' . $self->tokensp->{$_}->{re} . '/')) : "<$_>"} @{$rhsp}));
      if (defined($rank)) {
        $this .= sprintf(' rank=>%d', $rank);
      }
      if (defined($min)) {
        $this .= sprintf(' min=>%d', $min);
      }
      if (defined($action)) {
        $this .= sprintf(' action=>%s', $action);
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

hint			::= RANK | ACTION | ASSOIC

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
