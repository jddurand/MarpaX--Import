# *****************************************************************************
#
package MarpaX::Import::Grammar;
use strict;
use diagnostics;
use Log::Any qw/$log/;
use Carp;
#
# *****************************************************************************

my %MEMBERS;
sub BEGIN {
    %MEMBERS = (
                grammarp => {},
                tokensp  => {},
                rulesp   => [],
                g0rulesp => {},
                actionsp => {},
                generated_lhsp => {},
                actions_to_dereferencep => {},
                event_if_expectedp => {},
                predictionp => {},
                completionp => {},
                ruleid2ip => [],
                dotsp => {},
                actions_wrappedp => {},
                );
    foreach (keys %MEMBERS) {
	my $this = "*$_ = sub {
	    my \$self = shift;
	    if (\@_) {
		\$self->{$_} = shift;
	    }
	    return \$self->{$_};
	}";
	do {eval $this; 1;} || die "$this, $@\n";
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

    my $self = {};
    foreach (keys %MEMBERS) {
      if (defined($optp) && exists($optp->{$_})) {
        $self->{$_} = $optp->{$_};
	delete($optp->{$_});
      } else {
        $self->{$_} = $MEMBERS{$_};
      }
    }

    if (defined($optp) && %{$optp}) {
	croak "Unknown option(s): " . join(', ', keys %{$optp}) . "\n";
    }

    bless($self, $class);

    return $self;
}

###############################################################################
# string2print
###############################################################################
sub string2print {
    my ($self, $string) = @_;

    $string =~ s/[^[:print:]]/sprintf('x\\{%x}', ord($&))/eg;

    return $string;
}

###############################################################################
# print - should be reserved to print anonymous callbacks
###############################################################################
sub print {
    my ($self, $string) = @_;

    return $string;
}

###############################################################################
# rhs_as_string
###############################################################################
sub rhs_as_string {
    my ($self, $irule, $irhs, $rhs, $bnf2slipb) = @_;

    if (! defined($bnf2slipb)) {
	$bnf2slipb = 0;
    }

    my @rc = ();
    if (defined($rhs)) {
	if (! $bnf2slipb && exists($self->event_if_expectedp->{$rhs})) {
	    push(@rc, join("\n\t", map {'.?' . $self->print($_->{orig})} @{$self->event_if_expectedp->{$rhs}}));
	    push(@rc, "\n\t");
	}
	if (! $bnf2slipb && exists($self->predictionp->{$rhs})) {
	    push(@rc, join("\n\t", map {'.' . $self->print($_->{orig})} @{$self->predictionp->{$rhs}}));
	    push(@rc, "\n\t");
	}
	if (exists($self->tokensp->{$rhs})) {
	    if (exists($self->tokensp->{$rhs}->{orig})) {
		push(@rc, $self->string2print($self->tokensp->{$rhs}->{orig}));
	    } else {
		push(@rc, $self->tokensp->{$_}->{re});
	    }
	    if (! $bnf2slipb) {
		if (exists($self->tokensp->{$rhs}->{orig_pre}) && defined($self->tokensp->{$rhs}->{orig_pre})) {
		    push(@rc, sprintf("pre => %s\n\t",  $self->print($self->tokensp->{$rhs}->{orig_pre})));
		}
		if (exists($self->tokensp->{$rhs}->{orig_post}) && defined($self->tokensp->{$rhs}->{orig_post})) {
		    push(@rc, sprintf("post => %s\n\t",  $self->print($self->tokensp->{$rhs}->{orig_post})));
		}
		if (exists($self->tokensp->{$rhs}->{orig_code}) && defined($self->tokensp->{$rhs}->{orig_code})) {
		    push(@rc, sprintf("code => %s\n\t",  $self->print($self->tokensp->{$rhs}->{orig_code})));
		}
	    }
	} else {
	    push(@rc, "<$rhs>");
	}
	if (! $bnf2slipb && exists($self->completionp->{$rhs})) {
	    push(@rc, join("\n\t", map {'.' . $self->print($_->{orig})} @{$self->completionp->{$rhs}}));
	    push(@rc, "\n\t");
	}
    }

    return "@rc";
}

###############################################################################
# rules_as_string_g0b
###############################################################################
sub rules_as_string_g0b {
    my ($self, $g0b, $bnf2slipb) = @_;

    my $rc = '';
    my @rc = ();
    push(@rc, '');
    push(@rc, '################################');
    if ($g0b) {
      push(@rc, '# G0 rules');
    } else {
      push(@rc, '# G1 rules');
    }
    push(@rc, '################################');
    push(@rc, '');
    my $previous_lhs = undef;

    my $irule = -1;
    foreach (@{$self->rulesp}) {
	++$irule;
	my $rulep = $_;
	my ($lhs,
	    $rhsp,
	    $min,
	    $action,
	    $mask,
	    $bless,
	    $rank,
	    $separator,
	    $proper) = ($rulep->{lhs},
			$rulep->{rhs},
			exists($rulep->{min})       ? $rulep->{min}       : undef,
			exists($rulep->{action})    ? $rulep->{action}    : undef,
			exists($rulep->{mask})      ? $rulep->{mask}      : undef,
			exists($rulep->{bless})     ? $rulep->{bless}     : undef,
			exists($rulep->{rank})      ? $rulep->{rank}      : undef,
			exists($rulep->{separator}) ? $rulep->{separator} : undef,
			exists($rulep->{proper})    ? $rulep->{proper}    : undef);
	if ((  $g0b && ! exists($self->{g0rulesp}->{$lhs})) ||
	    (! $g0b &&   exists($self->{g0rulesp}->{$lhs}))) {
	    next;
	}
	my $first = '';
	my $lhsout = '';
	if (! $bnf2slipb) {
	    $lhsout = "<$lhs>";
	} else {
	    if (substr($lhs, $[, 1) eq ':') {
		#
		## Reserved name, should be writen as-is
		#
		$lhsout = $lhs;
	    } else {
		$lhsout = "<$lhs>";
	    }
	}
	$first .= "$lhsout\t" . (($g0b && $bnf2slipb) ? '~' : '::=') . "\t";
	if (defined($previous_lhs)) {
	    if ($previous_lhs eq $lhs) {
		if (! $bnf2slipb || @{$rhsp}) {
		    #
		    ## This is a '|'
		    #
		    $first = sprintf("%s\t|\t", ' ' x length($lhsout));
		} else {
		    #
		    ## bnf2slif mode and this is an empty rule
		    #
		}
	    } else {
		#
		## This is a new lhs
		#
		push(@rc, '');
	    }
	}
	my $irhs = 0;
	my $this = sprintf('%s%s', $first, join(' ', (map {$self->rhs_as_string($irule, $irhs++, $_, $bnf2slipb)} @{$rhsp}), $self->rhs_as_string($irule, $irhs++, undef, $bnf2slipb)));
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
	if (defined($mask)) {
	    $this .= sprintf(' mask=>[%s]', join(',', @{$mask}));
	}
	if (defined($action)) {
	    if (exists($self->actionsp->{$action})) {
		#
		## Intentionally, no string2print here
		#
                if (! $bnf2slipb) {
                  $this .= sprintf(' action=>%s /* %s */', $self->actionsp->{$action}->{orig}, $action);
                } else {
                  $this .= sprintf(' action=>%s', $self->actionsp->{$action}->{orig});
                }
	    } else {
		$this .= sprintf(' action=>%s', $action);
	    }
	}
	if (defined($bless)) {
	    $this .= sprintf(' bless=>%s', $bless);
	}
	push(@rc, $this);
	$previous_lhs = $lhs;
    }

    $rc = join("\n", @rc);

    return "$rc\n";
}

###############################################################################
# rules_as_string
###############################################################################
sub rules_as_string {
    my ($self, $bnf2slipb) = @_;

    $bnf2slipb ||= 0;

    return $self->rules_as_string_g0b(0, $bnf2slipb) . $self->rules_as_string_g0b(1, $bnf2slipb);
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

ACTION			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*action[ \f\t\r]*=>[ \f\t\r]*([[:alpha:]][[:word:]]*|$RE{balanced}{-parens=>'{}'})/

BLESS 			::=	/\G[ \f\t\r]*\n?[ \f\t\r]*bless[ \f\t\r]*=>[ \f\t\r]*([[:alpha:]][[:word:]]*)/

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

hint			::= RANK | ACTION | BLESS | ASSOC | SEPARATOR | PROPER

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
