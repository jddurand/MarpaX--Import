use version; # perl 5.10 minimum, which Marpa's requirement as well
use ExtUtils::MakeMaker;
use File::Find;
use File::Spec;

my @t = ();
find(
    sub {
	#
	## Sorry guys, but on Windows $File::Find::name has a slash; not a backslash
	#
	push(@t, File::Spec->canonpath(File::Spec->catfile($File::Find::dir, $_))) if (/\.t$/ && -f $_);
    },
    't');
my @tests = sort @t;

my %args = (
    NAME              => 'MarpaX::Import',
    VERSION_FROM      => 'lib/MarpaX/Import.pm', # finds $VERSION
    PREREQ_PM         => {
	'Marpa::R2'   =>  0,
	'Regexp::Common' => 0,
	'Log::Any'    => 0
    },
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
     (ABSTRACT_FROM  => 'lib/MarpaX/Import.pm', # retrieve abstract from module
      AUTHOR         => 'Jean-Damien Durand <jeandamiendurand@free.fr>') : ()),
    , test => { TESTS => "@tests" } # Works on all platforms because there is no special char, no space, etc
    );

my $TEST_REQUIRES = {
    'Test'          =>  0,
    'Test::More'    =>  0,
    'Log::Log4perl' =>  0,
    'Log::Any::Adapter::Log4perl' => 0
};

if (version->parse($ExtUtils::MakeMaker::VERSION) >= version->parse('6.63_03')) {
    $args{TEST_REQUIRES} = $TEST_REQUIRES;
} else {
    $args{BUILD_REQUIRES} = $TEST_REQUIRES;
}

WriteMakefile(%args);
