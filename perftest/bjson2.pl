use Benchmark;

use lib 'lib';
use MarpaX::Import::JSON;
use Log::Log4perl qw /:easy/;
use Log::Any::Adapter;
use FindBin qw/$Bin/;

Log::Log4perl::init(File::Spec->catfile($Bin, 'log4perl.conf'));
Log::Any::Adapter->set('Log4perl');


my $json_str = q${"test":[1,2,3,4,5],"test2":[],"test3":[]}$;
my $p2 = MarpaX::Import::JSON->new;
# PERL5OPT=-d:NYTProf NYTPROF=start=no perl bjson2.pl
DB::enable_profile();
foreach (0..100) {
    print STDERR "$_\n";
    $p2->parse($json_str);
}
DB::disable_profile();

