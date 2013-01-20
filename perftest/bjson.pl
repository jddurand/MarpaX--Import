use Benchmark;

use lib 'lib';
use JSON::XS;
use JSON::PP 'decode_json';
use MarpaX::JSON;
use MarpaX::Import::JSON;
use Benchmark qw/:hireswallclock :all/;

my $json_str = q${"test":[1,2,3,4,5],"test2":[],"test3":[]}$;

my $p1 = MarpaX::JSON->new;
my $p2 = MarpaX::Import::JSON->new;

cmpthese(-4, {
    'JSON::XS'             => sub { JSON::XS::decode_json($json_str);},
    'JSON::PP'             => sub { JSON::PP::decode_json($json_str);},
    'MarpaX::JSON'         => sub { $p1->parse($json_str); },
    'MarpaX::Import::JSON' => sub { $p2->parse($json_str); },
});
