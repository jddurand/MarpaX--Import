#!/usr/bin/perl

package load_calculator_expressions;

use strict;
use diagnostics;

sub new {
  return bless {}, shift;
}

sub load {
    my $self = shift;
    my $file = shift;
    
    my @expressions = ();
    
    open(FILE, '<', $file) || die "Cannot open $file, $!\n";
    while (defined($_ = <FILE>)) {
        s/^\s*//;
        s/\s*$//;
        s/^#.*//;
        next if (length($_) <= 0);
        push(@expressions, $_);
    }
    close(FILE) || warn "Cannot close $file, $!\n";
    
    return(@expressions);
}

1;
