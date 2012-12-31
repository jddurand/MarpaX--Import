#!/usr/bin/perl

#
## C.f. http://osdir.com/ml/lang.perl.modules.log4perl.devel/2007-03/msg00030.html
#

package MarpaX::Import::MarpaLogger;
use strict;
use diagnostics;
use Carp;
use Log::Any;

sub BEGIN {
    #
    ## Some Log implementation specificities
    #
    my $have_Log_Log4perl = eval 'use Log::Log4perl; 1;' || 0;
    if ($have_Log_Log4perl != 0) {
	#
	## Here we put know hooks for logger implementations
	#
	Log::Log4perl->wrapper_register(__PACKAGE__);
    }
}

sub TIEHANDLE {
  my($class, %options) = @_;

  my $self = {
              level => exists($options{level}) ? ($options{level} || 'trace') : 'trace',
              category => exists($options{category}) ? ($options{category} || '') : '',
             };

  $self->{logger} = Log::Any->get_logger(category => $self->{category});

  bless $self, $class;
}

sub PRINT {
  my $self = shift;
  my $logger = $self->{logger} || '';
  my $level = $self->{level} || '';
  if ($logger && $level) {
    $logger->trace(@_);
  }
  return 1;
}

sub PRINTF {
  my $self = shift;
  return $self->PRINT(sprintf(@_));
}

sub UNTIE {
  my ($obj, $count) = @_;
  if ($count) {
    carp "untie attempted while $count inner references still exist";
  }
}

1;
