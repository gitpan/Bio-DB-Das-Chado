# $Id: Chado.pm,v 1.11 2009-08-25 19:29:43 scottcain Exp $

=head1 NAME

Bio::DB::Das::Chado - DAS-style access to a chado database

=head1 SYNOPSIS

  # Open up a feature database
                 $db    = Bio::DB::Das::Chado->new(
                            -dsn  => 'dbi:Pg:dbname=gadfly;host=lajolla'
                            -user => 'jimbo',
                            -pass => 'supersecret',
                                       );

  @segments = $db->segment(-name  => '2L',
                           -start => 1,
			   -end   => 1000000);

  # segments are Bio::Das::SegmentI - compliant objects

  # fetch a list of features
  @features = $db->features(-type=>['type1','type2','type3']);

  # invoke a callback over features
  $db->features(-type=>['type1','type2','type3'],
                -callback => sub { ... }
		);

  # get all feature types
  @types   = $db->types;

  # count types
  %types   = $db->types(-enumerate=>1);

  @feature = $db->get_feature_by_name($class=>$name);
  @feature = $db->get_feature_by_target($target_name);
  @feature = $db->get_feature_by_attribute($att1=>$value1,$att2=>$value2);
  $feature = $db->get_feature_by_id($id);

  $error = $db->error;

=head1 DESCRIPTION

Bio::DB::Das::Chado allows DAS style access to a Chado database, getting
SeqFeatureI-compliant BioPerl objects and allowing GBrowse to access
a Chado database directly.

=head1 FEEDBACK

=head2 Mailing Lists

User feedback is an integral part of the evolution of this and other
GMOD modules. Send your comments and suggestions preferably to one
of the GMOD mailing lists.  Your participation is much appreciated.

  gmod-gbrowse@lists.sourceforge.com

=head2 Reporting Bugs

Report bugs to the GMOD bug tracking system at SourceForge to help us keep
track the bugs and their resolution. 

  http://sourceforge.net/tracker/?group_id=27707&atid=391291


=head1 AUTHOR

Scott Cain <scain@cpan.org>

=head1 LICENSE

This software may be redistributed under the same license as perl.

=head1 APPENDIX

The rest of the documentation details each of the object
methods. Internal methods are usually preceded with a _

=cut

#'

package Bio::DB::Das::Chado;
use strict;

use Bio::DB::Das::Chado::Segment;
use Bio::Root::Root;
use Bio::DasI;
use Bio::PrimarySeq;
use Bio::DB::GFF::Typename;
use DBI;
use Bio::SeqFeature::Lite;
use Carp qw(longmess);
use vars qw($VERSION @ISA);

use Data::Dumper;

use constant SEGCLASS => 'Bio::DB::Das::Chado::Segment';
use constant MAP_REFERENCE_TYPE => 'MapReferenceType'; #dgg
use constant DEBUG => 0;

$VERSION = 0.34;
@ISA = qw(Bio::Root::Root Bio::DasI);

=head2 new

 Title   : new
 Usage   : $db    = Bio::DB::Das::Chado(
                            -dsn  => 'dbi:Pg:dbname=gadfly;host=lajolla'
			    -user => 'jimbo',
			    -pass => 'supersecret',
                                       );

 Function: Open up a Bio::DB::DasI interface to a Chado database
 Returns : a new Bio::DB::Das::Chado object
 Args    :

=over

=item -dsn [dsn string]

A full dbi dsn string for the database, optionally including host and port
information, like "dbi:Pg:dbname=chado;host=localhost;port=5432".

=item -user [username]

The database user name.

=item -pass [password]

The users password for the database.

=item -organism [common_name|abbreviation|"Genus species"]

Used to specify the organism that the features should be drawn from in
Chado instances that have more than one organism.  The argument can be
the common name, the abbreviation or "Genus species".  Since common name
and abbreviation are not guaranteed to be unique, if one of those is supplied
and it corresponds to more than one organism_id, the Chado adaptor will die.
Since the combination is guaranteed to be unique by table constraints, 
supplying "Genus species" should always work.

=item -srcfeatureslice [1|0] default: 1

Setting this to 1 will enable searching for features using a function and
a corresponding index that can significantly speed searches, as long as
the featureloc_slice function is present in the Chado instance (all
"modern" instances of Chado do have this function).  Since it available
in nearly all Chado instances, in a future release of this adaptor,
the default value of -srcfeatureslice will be set to 1 (on).

=item -inferCDS [1|0] default: 0

Given mRNA features that have exons and polypeptide features as children,
when inferCDS is set, the Chado adaptor will calculate the intersection
of the exons and polypeptide features and create CDS features that result.
This is generally needed when using gene and mRNA features with glyphs in
GBrowse that show subparts, like the gene and processed_transcript glyphs.
Since this is almost always required, in a future release of this adaptor,
the default will be switched to 1 (on).

=item -fulltext [1|0] default: 0

This item allows full text searching of various Chado text fields,
including feature.name, feature.uniquename, synonym.synonym_sgml,
dbxref.accession, and all_feature_names.name (which fequently includes
featureprop.value, depending on how all_feature_names is configured).  Note
that to use -fulltext, you must run the preparation script, 
gmod_chado_fts_prep.pl, on the database, and in addition, it might 
be a good idea to set up a cronjob to keep the all_feature_names
materialized view up to date with the materialized view tool,
gmod_materialized_view_tool.pl.

=item -recursivMapping [1|0] default: 0

In the case where features are mapped to a "small" srcfeature (like
a contig) and then that small feature is mapped to a larger feature 
(like a chromosome), setting -recursivMapping will allow the Chado
adaptor to calculate the coordinates of the feature on the larger
feature even though it isn't explicitly mapped to it.  The Chado adaptor
suffers an approximately 20% performance penalty to do this mapping.

=item -allow_obsolete [1|0] default: 0

If set to 1, allow_obsolete will tell the Chado adaptor to ignore the
feature.is_obsolete column when querying to find features.

=item -enable_seqscan [1|0] default: 1

If set to zero, the -enable_seqscan will send a query planner hint to the
PostgreSQL server to make it more costly to do sequential scans on a table.
This is generally not necessary, as the query planner in Pg 8+ is smarter
than it used to be.

=item -do2Level [1|0] default: 0

do2Level is a flag for specifying that two "levels" at most of features should
be fetch when getting child features.  This flag is generally unnecessary as
Bio::Graphics::Glyph supports specifying on a per glyph basis what should
be fetch.  Use of this flag is incompatible with the -recursivMapping flag.

=item -reference_class [SO type name]

Used to specify what the "base type" is.  Typically, this would be chromosome
or contig, but setting it is only necessary in the case where features
are mapped to more than one srcfeature and you don't want to use the
one that is lowest on the graph.  For example, you have polypeptides that are
mapped to chromosomes and motifs that are mapped to polypeptides.  If you
want to display the motifs on the polypeptide, you need to set "polypeptide"
as the argument for -reference_class.

=item -tripal [1|0] default: 0

If turned on, the tripal flag tells the adaptor that it is dealing with
a Chado instance that is working with Tripal, and so the query to fetch
features may fail with regard to analysis features.  This flag attempts to 
prevent that.  It may mean that analysis features (like similarity results)
will be inaccessible to the adaptor, or at least scores associated with them
will be, depending on how they were loaded.

=back

=cut

# create new database accessor object
# takes all the same args as a Bio::DB::BioDB class
sub new {
  my $proto = shift;
  my $self = bless {}, ref($proto) || $proto;

  my %arg =  @_;

  my $dsn      = $arg{-dsn};
  my $username = $arg{-user};
  my $password = $arg{-pass};
  my $refclass = $arg{-reference_class};
  my $tripal   = $arg{-tripal};

  $self->{db_args}->{dsn}      = $dsn;
  $self->{db_args}->{username} = $username;
  $self->{db_args}->{password} = $password;

  my $dbh = DBI->connect( $dsn, $username, $password )
    or $self->throw("unable to open db handle");
  $self->dbh($dbh);

    warn "$dbh\n" if DEBUG;

# determine which cv to use for SO terms

  $self->sofa_id(1); 

    warn "SOFA id to use: ",$self->sofa_id() if DEBUG;

# get the cvterm relationships here and save for later use

  my $cvterm_query="select ct.cvterm_id,ct.name as name, c.name as cvname
                           from cvterm ct, cv c
                           where ct.cv_id=c.cv_id and
                           (c.name IN (
                               'relationship',
                               'relationship type','Relationship Ontology',
                               'autocreated')
                            OR c.cv_id = ?)";

    warn "cvterm query: $cvterm_query\n" if DEBUG;

  my $sth = $self->dbh->prepare($cvterm_query)
    or warn "unable to prepare select cvterms";

  $sth->execute($self->sofa_id()) or $self->throw("unable to select cvterms");

#  my $cvterm_id  = {}; replaced with better-named variables
#  my $cvname = {};

  my(%term2name,%name2term) = ({},{});
  my %termcv=();
  
  while (my $hashref = $sth->fetchrow_hashref) {
    $term2name{ $hashref->{cvterm_id} } = $hashref->{name};
    $termcv{ $hashref->{cvterm_id} } = $hashref->{cvname}; # dgg
    
    #this addresses a bug in gmod_load_gff3 (Scott!), which creates a 'part_of'
    #term in addition to the OBO_REL one that already exists!  this will also
    #help with names that exist in both GO and SO, like 'protein'.
    # dgg: but this array is bad for callers of name2term() who expect scalar result 
    #    mostly want only sofa terms
   
    if(defined($name2term{ $hashref->{name} })){ #already seen this name

      if(ref($name2term{ $hashref->{name} }) ne 'ARRAY'){ #already array-converted

        $name2term{ $hashref->{name} } = [ $name2term{ $hashref->{name} } ];

      }

      push @{ $name2term{ $hashref->{name} } }, $hashref->{cvterm_id};

    } else {

      $name2term{ $hashref->{name} }      = $hashref->{cvterm_id};

    }
  }
  $sth->finish;

  $self->term2name(\%term2name);
  $self->name2term(\%name2term, \%termcv);

  #Recursive Mapping
  $self->recursivMapping($arg{-recursivMapping} ? $arg{-recursivMapping} : 0);

  $self->inferCDS($arg{-inferCDS} ? $arg{-inferCDS} : 0);
  $self->allow_obsolete($arg{-allow_obsolete} ? $arg{-allow_obsolete} : 0);

  if (exists($arg{-enable_seqscan}) && ! $arg{-enable_seqscan}){
    $self->dbh->do("set enable_seqscan=0");
  }

  $self->srcfeatureslice(defined $arg{-srcfeatureslice} ? $arg{-srcfeatureslice} : 1);
  $self->do2Level($arg{-do2Level} ? $arg{-do2Level} : 0);

  if ($arg{-organism}) {
    $self->organism_id($arg{-organism});
  }

  #determine if all_feature_names view or table exist
  #$self->use_all_feature_names();

  #determine the type_id of the ref class and cache it
  $self->refclass($self->name2term($refclass));

  $self->fulltext($arg{-fulltext});
  $self->tripal($arg{-tripal});

  return $self;
}

=head2 feature_summary

=over

=item Usage

  $obj->feature_summary()

=item Function

This function is based on Bio::DB::SeqFeature::Store->feature_summary.  
The text that follows comes from it's documtation:

This method is used to get coverage density information across a
region of interest. You provide it with a region of interest, optional
a list of feature types, and a count of the number of bins over which
you want to calculate the coverage density. An object is returned
corresponding to the requested region. It contains a tag called
"coverage" that will return an array ref of "bins" length. Each
element of the array describes the number of features that overlap the
bin at this postion.

Note that this method uses an approximate algorithm that is only
accurate to 500 bp, so when dealing with bins that are smaller than
1000 bp, you may see some shifting of counts between adjacent bins.

Although an -iterator option is provided, the method only ever returns
a single feature, so this is fairly useless.

=item Returns

A single feature containing summary data, or an interator containing
that one feature.

=item Arguments

  -seq_id        Sequence ID for the region
  -start         Start of region
  -end           End of region
  -type/-types   Feature type of interest or array ref of types
  -bins          Number of bins across region. Defaults to 1000.
  -iterator      Return an iterator across the region

=back

=cut

sub feature_summary {
    my $self = shift;
    my ($seq_name,$seq_id,$ref,$start,$stop,$end,$types,$type,$primary_tag,$bins,$iterator) =
        $self->_rearrange(['SEQID','SEQ_ID','REF','START','STOP','END',
                   'TYPES','TYPE','PRIMARY_TAG',
                   'BINS',
                   'ITERATOR',
                  ],@_);

    $seq_name ||=$seq_id ||=$ref;
    $end      ||=$end;
    $types    ||=$type   ||=$primary_tag;

    warn $types if DEBUG;

    my ($coverage,$tag) = $self->coverage_array(-seqid=> $seq_name,
                                                -start=> $start,
                                                -end  => $end,
                                                -type => $types,
                                                -bins => $bins) or return;
    my $score = 0;
    for (@$coverage) { $score += $_ }
    $score /= @$coverage;

    my $feature = Bio::SeqFeature::Lite->new(-seq_id => $seq_name,
                                             -start  => $start,
                                             -end    => $end,
                                             -type   => $tag,
                                             -score  => $score,
                                             -attributes =>
                                             { coverage => [$coverage] });

    my @features = ($feature);
    return $iterator
           ? Bio::DB::Das::ChadoIterator->new(\@features) 
           : $feature;
}


=head2 coverage_array

=over

=item Usage

  $obj->coverage_array()

=item Function

Calculates the coverage/density of a particular feature type
over a range.

=item Returns

A reference to the coverage array, or if called in an array
context, a two element array with the reference to the coverage
array first and the type that it was called with as the second
element.

=item Arguments

seqid
start
stop
type
bins

=back

This is based on the method of the same name in
Bio::DB::SeqFeature::Store::DBI::mysql

=cut

sub coverage_array {
    my $self = shift;
    my ($seq_name,$seq_id,$ref,$start,$end,$stop,$types,$type,$primary_tag,$bins) =
        $self->_rearrange(['SEQID','SEQ_ID','REF','START','STOP','END',
                   'TYPES','TYPE','PRIMARY_TAG','BINS'],@_);

    $seq_name ||= $seq_id ||= $ref;
    $types    ||= $type   ||= $primary_tag;
    $end      ||= $stop;

    my $summary_bin_size = 1000;
    $bins  ||= 1000;
    $start ||= 1;
    my $segment = $self->segment(-name =>$seq_name) or $self->throw("unknown seq_id $seq_name");
    $end   ||= $segment->end;
  
    my $binsize = ($end-$start+1)/$bins;
    my $seqid   = $segment->feature_id;

    warn "$seqid in coverage array" if DEBUG;

    return [] unless $seqid;

    # where each bin starts
    my @his_bin_array = map {$start + $binsize * $_}       (0..$bins);
    my @sum_bin_array = map {int(($_-1)/$summary_bin_size)} @his_bin_array;

    my $interval_stats    = 'gff_interval_stats';
   
    # pick up the type ids

#WARNING: potential bug below.  This query and the loop that processes
#it is from Lincoln's implementation for SeqFeature::Store.  The query
#seems to rely on getting the results back sorted even though the
#query doesn't explicitly sort (the ORDER BY commented out was from me)
#With sorting the processing takes much longer, so I'm leaving it out
#for now, but reimplementing might be a good idea.

    my %bins;
    my $sql = <<END;
SELECT bin,cum_count
  FROM $interval_stats
  WHERE (typeid=? OR typeid like ? ) AND bin >=? AND srcfeature_id =?
 -- ORDER BY bin 
  LIMIT 1
END
;

    my $sth = $self->dbh->prepare($sql);

    my @t;
    if (ref $types eq 'ARRAY') {
        @t = @$types;
    }
    else {
        @t = ($types);
    }

    warn join(" ", @t) . " types in coverage array" if DEBUG;

    eval {
        for my $typeid (@t) {
            my $typestr = $self->_types_sql($typeid); 

            warn "$typestr typestr in coverage array" if DEBUG;

            for (my $i=0;$i<@sum_bin_array;$i++) {

                my @args = ($typestr,$typestr,$sum_bin_array[$i],$seqid);

                $sth->execute(@args) or $self->throw($sth->errstr);
                my ($bin,$cum_count) = $sth->fetchrow_array;
                push @{$bins{$typeid}},[$bin,$cum_count];
            }
        }
    };


    return unless %bins;

    my @tags;
    my @merged_bins;
    my $firstbin = int(($start-1)/$binsize);
    for my $type (keys %bins) {
        push @tags, $type;
        my $arry       = $bins{$type};
        my $last_count = $arry->[0][1];
        my $last_bin   = -1;
        my $i          = 0;
        my $delta;
        for my $b (@$arry) {
            my ($bin,$count) = @$b;
            $delta              = $count - $last_count if $bin > $last_bin;
            $merged_bins[$i++]  = $delta;
            $last_count         = $count;
            $last_bin           = $bin;
        }
    }

    my $report_tag = join(",",@tags);
    return wantarray ? (\@merged_bins,$report_tag) : \@merged_bins;
}


sub _types_sql {
  my $self  = shift;
  my $type = shift;
  my ($primary_tag,$source_tag,$typestr);

    if (ref $type && $type->isa('Bio::DB::GFF::Typename')) {
      $primary_tag = $type->method;
      $source_tag  = $type->source;
    } else {
      ($primary_tag,$source_tag) = split ':',$type,2;
    }

    if (defined $source_tag) {
      if (length($primary_tag)) {
        $typestr =  "$primary_tag:$source_tag";
      }
      else {
        $typestr =  "%:$source_tag";
      }
    } else {
      $typestr = "$primary_tag:%";
    }

  return ($typestr);
}

=head2 tripal 

=over

=item Usage

  $obj->tripal()        #get existing value
  $obj->tripal($newval) #set new value

=item Function

Flag to identfy Chado database that are working with Tripal

=item Returns

value of tripal (a scalar)

=item Arguments

new value of tripal (to set)

=back

=cut

sub tripal {
    my $self = shift;
    my $tripal = shift if defined(@_);
    return $self->{'tripal'} = $tripal if defined($tripal);
    return $self->{'tripal'};
}



=head2 fulltext

=over

=item Usage

  $obj->fulltext()        #get existing value
  $obj->fulltext($newval) #set new value

=item Function

Flag to govern the use of full text searching queries

=item Returns

value of fulltext (a scalar)

=item Arguments

new value of fulltext (to set)

=back

=cut

sub fulltext {
    my $self = shift;
    my $fulltext = shift if defined(@_);
    return $self->{'fulltext'} = $fulltext if defined($fulltext);
    return $self->{'fulltext'};
}


=head2 refclass

=over

=item Usage

  $obj->refclass()        #get existing value
  $obj->refclass($newval) #set new value

=item Function

=item Returns

value of the reference class's cvterm_id (a scalar)

=item Arguments

new value of the reference class's cvterm_id (to set)

=back

=cut

sub refclass {
    my $self = shift;
    my $refclass = shift if defined(@_);
    return $self->{'refclass'} = $refclass if defined($refclass);
    return $self->{'refclass'};
}


=head2 use_all_feature_names

  Title   : use_all_feature_names
  Usage   : $obj->use_all_feature_names()
  Function: set or return flag indicating that all_feature_names view is present
  Returns : 1 if all_feature_names present, 0 if not
  Args    : to return the flag, none; to set, 1


=cut

sub use_all_feature_names {
    my ($self, $flag) = @_;

    return $self->{use_all_feature_names} = $flag 
        if defined($flag);
    return $self->{use_all_feature_names} 
        if defined $self->{use_all_feature_names};

    #now determine if either a view or table named all_feature_names is present
    my $query 
        = "SELECT relkind FROM pg_class WHERE relname = 'all_feature_names'";

    my $exists = $self->dbh->prepare($query);
    $exists->execute or warn "all_feature_names query failed: $!";

    my ($kind) = $exists->fetchrow_array; 
    if ($kind and ($kind eq 'r' or $kind eq 'v')) {
        $self->{use_all_feature_names} = 1;
    }
    elsif ($kind) {
        warn "all_feature_names: This option shouldn't happen--setting use_all_feature_names to zero.";
        $self->{use_all_feature_names} = 0;
    }
    else {
        $self->{use_all_feature_names} = 0;
    }
    $exists->finish;

    return $self->{use_all_feature_names};
}

=head2 organism_id

  Title   : organism_id
  Usage   : $obj->organism_id()
  Function: set or return the organism_id
  Returns : the value of the id
  Args    : to return the flag, none; to set, the common name of the organism

If -organism is set when the Chado feature is instantiated, this method
queries the database with the common name to cache the organism_id.

=cut

sub organism_id {
    my $self = shift;
    my $organism_name = shift;

    if (!$organism_name) {
        return $self->{'organism_id'};
    }

    my $dbh = $self->dbh;

    #if there is a space in the name, check genus species
    if ($organism_name =~ /(\S+?)\s+(.+)/) {
        my $genus   = $1;
        my $species = $2;
        my $species_query = $dbh->prepare("SELECT organism_id FROM organism WHERE genus = ? and species = 
?");
        $species_query->execute($genus, $species) or die "organism genus species query failed:$!";

        #don't need to check for multiple rows because of unique constraint
        if ($species_query->rows == 1) {
            my($organism_id) = $species_query->fetchrow_array;

            if ($organism_id) {
                return $self->{'organism_id'} = $organism_id;
            }

        }
    }

    #check common name
    my $org_query = $dbh->prepare("SELECT organism_id FROM organism WHERE common_name = ?");

    $org_query->execute($organism_name) or die "organism query failed:$!";

    #if more than one result for common name, croak
    if ($org_query->rows > 1) {
        $self->throw("The common organism name, $organism_name, is present more than once in the organism table; please use a more precice representation of the organism.");
    }
    elsif ($org_query->rows == 0 ) {
        #no--don't do anything here--let it go on to check other things
        #$self->throw("There is no organism in the organism table with a common name '$organism_name'; please check the spelling.");
    }
    else {
        my($organism_id) = $org_query->fetchrow_array;

        if ($organism_id) {
            return $self->{'organism_id'} = $organism_id;
        }
    }
    $org_query->finish;

    #check abbrev
    my $abbrev_query = $dbh->prepare("SELECT organism_id FROM organism WHERE abbreviation = ?");

    $abbrev_query->execute($organism_name) or die "organism abbrev query failed:$!";

    if ($abbrev_query->rows > 1) {
        $self->throw("The abbreviated organism name, $organism_name, is present more than once in the organism table; please use a more precice representation of the organism.");
    }
    elsif ($abbrev_query->rows == 0) {
        #do nothing in case another check is added after this one 
    }
    else {
        my($organism_id) = $abbrev_query->fetchrow_array;

        if ($organism_id) {
            return $self->{'organism_id'} = $organism_id;
        }
    }

    $self->throw("Tried everything to get an organism_id for '$organism_name' but failed; try 'genus species'");
    return; #of course, this return will never get used
}



=head2 inferCDS

  Title   : inferCDS
  Usage   : $obj->inferCDS()
  Function: set or return the inferCDS flag
  Returns : the value of the inferCDS flag
  Args    : to return the flag, none; to set, 1

Often, chado databases will be populated without CDS features, since
they can be inferred from a union of exons and polypeptide features.
Setting this flag tells the adaptor to do the inferrence to get
those derived CDS features (at some small performance penatly).

=cut

sub inferCDS {
    my $self = shift;

    my $flag = shift;
    return $self->{inferCDS} = $flag if defined($flag);
    return $self->{inferCDS};
}

=head2 allow_obsolete

  Title   : allow_obsolete
  Usage   : $obj->allow_obsolete()
  Function: set or return the allow_obsolete flag
  Returns : the value of the allow_obsolete flag
  Args    : to return the flag, none; to set, 1

The chado feature table has a flag column called 'is_obsolete'.  
Normally, these features should be ignored by GBrowse, but
the -allow_obsolete method is provided to allow displaying
obsolete features.

=cut

sub allow_obsolete {
    my $self = shift;
    my $allow_obsolete = shift if defined(@_);
    return $self->{'allow_obsolete'} = $allow_obsolete if defined($allow_obsolete);
    return $self->{'allow_obsolete'};
}


=head2 sofa_id

  Title   : sofa_id 
  Usage   : $obj->sofa_id()
  Function: get or return the ID to use for SO terms
  Returns : the cv.cv_id for the SO ontology to use
  Args    : to return the id, none; to determine the id, 1

=cut

sub sofa_id {
  my $self = shift;
  return $self->{'sofa_id'} unless @_;

  my $query = "select cv_id from cv where name in (
                     'SOFA',
                     'Sequence Ontology Feature Annotation',
                     'sofa.ontology')";

  my $sth = $self->dbh->prepare($query);
  $sth->execute() or $self->throw("trying to find SOFA");

  my $data = $sth->fetchrow_hashref(); 
  my $sofa_id = $$data{'cv_id'};

  $sth->finish;
  return $self->{'sofa_id'} = $sofa_id if $sofa_id;

  $query = "select cv_id from cv where name in (
                    'Sequence Ontology',
                    'sequence',
                    'SO')";

  $sth = $self->dbh->prepare($query);
  $sth->execute() or $self->throw("trying to find SO");

  $data = $sth->fetchrow_hashref();
  $sofa_id = $$data{'cv_id'};

  $sth->finish;
  return $self->{'sofa_id'} = $sofa_id if $sofa_id;

  $self->throw("unable to find SO or SOFA in the database!");
}

=head2 recursivMapping

  Title   : recursivMapping
  Usage   : $obj->recursivMapping($newval)
  Function: Flag for activating the recursive mapping (desactivated by default)
  Returns : value of recursivMapping (a scalar)
  Args    : on set, new value (a scalar or undef, optional)

  Goal : When we have a clone mapped on a chromosome, the recursive mapping maps the features of the clone on the chromosome.

=cut

sub  recursivMapping{
  my $self = shift;

  return $self->{'recursivMapping'} = shift if @_;
  return $self->{'recursivMapping'};
}

=head2 srcfeatureslice

  Title   : srcfeatureslice
  Usage   : $obj->srcfeatureslice
  Function: Flag for activating 
  Returns : value of srcfeatureslice
  Args    : on set, new value (a scalar or undef, optional)
  Desc    : Allows to use a featureslice of type featureloc_slice(srcfeat_id, int, int)
  Important : this and recursivMapping are mutually exclusives

=cut

sub  srcfeatureslice{
  my $self = shift;
  return $self->{'srcfeatureslice'} = shift if @_;
  return $self->{'srcfeatureslice'};
}

=head2 do2Level

  Title   : do2Level
  Usage   : $obj->do2Level
  Function: Flag for activating the fetching of 2levels in segment->features
  Returns : value of do2Level
  Args    : on set, new value (a scalar or undef, optional)

=cut

sub  do2Level{
  my $self = shift;
  return $self->{'do2Level'} = shift if @_;
  return $self->{'do2Level'};
}


=head2 dbh

  Title   : dbh
  Usage   : $obj->dbh($newval)
  Function:
  Returns : value of dbh (a scalar)
  Args    : on set, new value (a scalar or undef, optional)


=cut

sub dbh {
  my $self = shift;

  return $self->{'dbh'} = shift if @_;
  return $self->{'dbh'} if defined ($self->{'dbh'});

  #uh oh, there isn't already a dbh object, try to create one
  my $dsn        = $self->{db_args}->{dsn};
  my $username   = $self->{db_args}->{username};
  my $password   = $self->{db_args}->{password};

  my $dbh = DBI->connect( $dsn, $username, $password )
    or $self->throw("unable to open db handle");
  $self->{'dbh'} = $dbh;

  if (exists($self->{-enable_seqscan}) && ! $self->{-enable_seqscan}){
    $dbh->do("set enable_seqscan=0");
  }

  return $self->{'dbh'};
}

=head2 term2name

  Title   : term2name
  Usage   : $obj->term2name($newval)
  Function: When called with a hashref, sets cvterm.cvterm_id to cvterm.name 
            mapping hashref; when called with an int, returns the name
            corresponding to that cvterm_id; called with no arguments, returns
            the hashref.
  Returns : see above
  Args    : on set, a hashref; to retrieve a name, an int; to retrieve the
            hashref, none.

Note: should be replaced by Bio::GMOD::Util->term2name

=cut

sub term2name {
  my $self = shift;
  my $arg = shift;

  if(ref($arg) eq 'HASH'){
    return $self->{'term2name'} = $arg;
  } elsif($arg) {
    return $self->{'term2name'}{$arg};
  } else {
    return $self->{'term2name'};
  }
}


=head2 name2term

  Title   : name2term
  Usage   : $obj->name2term($newval)
  Function: When called with a hashref, sets cvterm.name to cvterm.cvterm_id
            mapping hashref; when called with a string, returns the cvterm_id
            corresponding to that name; called with no arguments, returns
            the hashref.
  Returns : see above
  Args    : on set, a hashref; to retrieve a cvterm_id, a string; to retrieve
            the hashref, none.

Note: Should be replaced by Bio::GMOD::Util->name2term

=cut

sub name2term {
  my $self = shift;
  my $arg = shift;
  my $cvnames = shift;

  if(ref($cvnames) eq 'HASH'){ $self->{'termcvs'} = $cvnames; }
  if(ref($arg) eq 'HASH'){
    return $self->{'name2term'} = $arg;
  } elsif($arg) {
    return $self->{'name2term'}{$arg};

#rather than trying to guess what a caller wants, the caller will have
#deal with what comes... (ie, a scalar or a hash).
#    my $val= $self->{'name2term'}{$arg};
#    if(ref($val)) {
#      #? use $cvnames scalar here to pick which cv?
#      my @val= @$val; 
#      foreach $val (@val) {
#        my $cv=  $self->{'termcvs'}{$val};
#        return $val if($cv =~ /^(SO|sequence)/i); # want sofa_id
#        }
#      return $val[0]; #? 1st is best guess
#      }
#    return $val;

  } else {
    return $self->{'name2term'};
  }
}

=head2 segment

 Title   : segment
 Usage   : $db->segment(@args);
 Function: create a segment object
 Returns : segment object(s)
 Args    : see below

This method generates a Bio::Das::SegmentI object (see
L<Bio::Das::SegmentI>).  The segment can be used to find overlapping
features and the raw sequence.

When making the segment() call, you specify the ID of a sequence
landmark (e.g. an accession number, a clone or contig), and a
positional range relative to the landmark.  If no range is specified,
then the entire region spanned by the landmark is used to generate the
segment.

Arguments are -option=E<gt>value pairs as follows:

 -name         ID of the landmark sequence.

 -class        A namespace qualifier.  It is not necessary for the
               database to honor namespace qualifiers, but if it
               does, this is where the qualifier is indicated.

 -version      Version number of the landmark.  It is not necessary for
               the database to honor versions, but if it does, this is
               where the version is indicated.

 -start        Start of the segment relative to landmark.  Positions
               follow standard 1-based sequence rules.  If not specified,
               defaults to the beginning of the landmark.

 -end          End of the segment relative to the landmark.  If not specified,
               defaults to the end of the landmark.

The return value is a list of Bio::Das::SegmentI objects.  If the method
is called in a scalar context and there are no more than one segments
that satisfy the request, then it is allowed to return the segment.
Otherwise, the method must throw a "multiple segment exception".

=cut

sub segment {
  my $self = shift;
  my ($name,$base_start,$stop,$end,$class,$version,$db_id,$feature_id,$srcfeature_id) 
                                         = $self->_rearrange([qw(NAME
								 START
                 STOP
								 END
								 CLASS
								 VERSION
                 DB_ID
                 FEATURE_ID
                 SRCFEATURE_ID )],@_);
  # lets the Segment class handle all the lifting.

  $end ||= $stop;
  return $self->_segclass->new($name,$self,$base_start,$end,$db_id,0,$feature_id,$srcfeature_id);
}

=head2 features

 Title   : features
 Usage   : $db->features(@args)
 Function: get all features, possibly filtered by type
 Returns : a list of Bio::SeqFeatureI objects
 Args    : see below
 Status  : public

This routine will retrieve features in the database regardless of
position.  It can be used to return all features, or a subset based on
their type

Arguments are -option=E<gt>value pairs as follows:

  -type      List of feature types to return.  Argument is an array
             of Bio::Das::FeatureTypeI objects or a set of strings
             that can be converted into FeatureTypeI objects.

  -callback   A callback to invoke on each feature.  The subroutine
              will be passed each Bio::SeqFeatureI object in turn.

  -attributes A hash reference containing attributes to match.

The -attributes argument is a hashref containing one or more attributes
to match against:

  -attributes => { Gene => 'abc-1',
                   Note => 'confirmed' }

Attribute matching is simple exact string matching, and multiple
attributes are ANDed together.

If one provides a callback, it will be invoked on each feature in
turn.  If the callback returns a false value, iteration will be
interrupted.  When a callback is provided, the method returns undef.

=cut

sub features {
  my $self = shift;
  my ($type,$types,$callback,$attributes,$iterator,$feature_id,$seq_id,$start,$end) = 
       $self->_rearrange([qw(TYPE TYPES CALLBACK ATTRIBUTES ITERATOR FEATURE_ID SEQ_ID START END)],
			@_);

  $type ||= $types; #GRRR

  warn "Chado,features: $type\n" if DEBUG;
  my @features = $self->_segclass->features(-type => $type,
                                            -attributes => $attributes,
                                            -callback => $callback,
                                            -iterator => $iterator,
                                            -factory  => $self,
                                            -feature_id=>$feature_id,
                                            -seq_id    =>$seq_id,
                                            -start     =>$start,
                                            -end       =>$end,
                                           );
  return @features;
}

sub get_seq_stream {
    my $self = shift;
    #warn "get_seq_stream args:@_";
    my ($type,$types,$callback,$attributes,$iterator,$feature_id,$seq_id,$start,$end) =
     $self->_rearrange([qw(TYPE TYPES CALLBACK ATTRIBUTES ITERATOR FEATURE_ID SEQ_ID START END)],
                        @_);

    my @features = $self->_segclass->features(-type => $type,
                                            -attributes => $attributes,
                                            -callback => $callback,
                                            -iterator => $iterator,
                                            -factory  => $self,
                                            -feature_id=>$feature_id,
                                            -seq_id    =>$seq_id,
                                            -start     =>$start,
                                            -end       =>$end,
                                           );

    return Bio::DB::Das::ChadoIterator->new(\@features);


}

=head2 types

 Title   : types
 Usage   : $db->types(@args)
 Function: return list of feature types in database
 Returns : a list of Bio::Das::FeatureTypeI objects
 Args    : see below

This routine returns a list of feature types known to the database. It
is also possible to find out how many times each feature occurs.

Arguments are -option=E<gt>value pairs as follows:

  -enumerate  if true, count the features

The returned value will be a list of Bio::Das::FeatureTypeI objects
(see L<Bio::Das::FeatureTypeI>.

If -enumerate is true, then the function returns a hash (not a hash
reference) in which the keys are the stringified versions of
Bio::Das::FeatureTypeI and the values are the number of times each
feature appears in the database.

NOTE: This currently raises a "not-implemented" exception, as the
BioSQL API does not appear to provide this functionality.

=cut

sub types {
  my $self = shift;
  my ($enumerate) =  $self->_rearrange([qw(ENUMERATE)],@_);
  $self->throw_not_implemented;
  #if lincoln didn't need to implement it, neither do I!
}

=head2 get_feature_by_alias, get_features_by_alias 

 Title   : get_features_by_alias
 Usage   : $db->get_feature_by_alias(@args)
 Function: return list of feature whose name or synonyms match
 Returns : a list of Bio::Das::Chado::Segment::Feature objects
 Args    : See below

This method finds features matching the criteria outlined by the
supplied arguments.  Wildcards (*) are allowed.  Valid arguments are:

=over

=item -name

=item -class

=item -ref (refrence sequence)

=item -start

=item -end 

=back

=cut


sub get_feature_by_alias {
  my $self = shift;
  my @args = @_;

  if ( @args == 1 ) {
      @args = (-name => $args[0]);
  }

  push @args, -operation => 'by_alias';

  return $self->_by_alias_by_name(@args);
} 

*get_features_by_alias = \&get_feature_by_alias;

=head2 get_feature_by_name, get_features_by_name

 Title   : get_features_by_name
 Usage   : $db->get_features_by_name(@args)
 Function: return list of feature whose names match
 Returns : a list of Bio::Das::Chado::Segment::Feature objects
 Args    : See below

This method finds features matching the criteria outlined by the
supplied arguments.  Wildcards (*) are allowed.  Valid arguments are:

=over

=item -name

=item -class

=item -ref (refrence sequence)

=item -start

=item -end

=back

=cut


*get_features_by_name  = \&get_feature_by_name; 

sub get_feature_by_name {
  my $self = shift;
  my @args = @_;

  warn "in get_feature_by_name, args:@args" if DEBUG;

  if ( @args == 1 ) {
      @args = (-name => $args[0]);
  }

  push @args, -operation => 'by_name';

  return $self->_by_alias_by_name(@args);
}

=head2 _by_alias_by_name

 Title   : _by_alias_by_name
 Usage   : $db->_by_alias_by_name(@args)
 Function: return list of feature whose names match
 Returns : a list of Bio::Das::Chado::Segment::Feature objects
 Args    : See below

A private method that implements the get_features_by_name and
get_features_by_alias methods.  It accepts the same args as
those methods, plus an addtional on (-operation) which is 
either 'by_alias' or 'by_name' to indicate what rule it is to
use for finding features.

=cut

sub _by_alias_by_name {
  my $self = shift;

  my ($name, $class, $ref, $base_start, $stop, $operation) 
       = $self->_rearrange([qw(NAME CLASS REF START END OPERATION)],@_);

  if ($name =~ /^id:(\d+)/) {
    my $feature_id = $1;
    return $self->get_feature_by_feature_id($feature_id);
  }

  my @temp_array = split /:/, $name;
  if (scalar @temp_array == 2) {
    if ($self->source2dbxref($temp_array[0]) > 0) {
      warn "assuming that the name with a colon ($name) is coming from a multiple hit search result (ie, is of the form 'source:name'";
      $name = $temp_array[1];
    }
  }

##I think this is where this should go...
  # We need to split the query on whitespaces, and replace the whitespace with &
  # so that we can get proper full test search on allquery terms [LP]
  # but it only make sense to do this for full text searching [Scott]
  $name = $self->_search_name_prep_spaces($name) if $self->fulltext;


  my $wildcard = 0;
  if ($name =~ /\*/) {
    $wildcard = 1;
    undef $class;
  }

  warn "name:$name in get_feature_by_name" if DEBUG;

#  $name = $self->_search_name_prep($name);

#  warn "name after protecting _ and % in the string:$name\n" if DEBUG;

  my (@features,$sth);
  
  # get feature_id
  # foreach feature_id, get the feature info
  # then get src_feature stuff (chromosome info) and create a parent feature,

  my ($select_part,$from_part,$where_part);

  if ($class) {
      #warn "class: $class";
      my $type = ($class eq 'CDS' && $self->inferCDS)
                 ? $self->name2term('polypeptide')
                 : $self->name2term($class);
      return unless $type;

      if (ref $type eq 'ARRAY') {
           $type = join(',',@$type);
      }
      elsif (ref $type eq 'HASH') {
           $type = join(',', map($$type{$_}, keys %$type) ); 
      }
      $from_part =  " feature f ";
      $where_part.= " AND f.type_id in ( $type ) ";
  }

  if ($self->organism_id and $operation eq 'by_alias') {
      $where_part.= $self->use_all_feature_names()
                  ? " AND afn.organism_id =".$self->organism_id
                  : " AND f.organism_id =".$self->organism_id;
  }
  elsif ($self->organism_id) {
      $where_part.= " AND f.organism_id =".$self->organism_id;
  }

  if ( $operation eq 'by_alias') {
   if ($self->use_all_feature_names()) {
    $select_part = "select distinct afn.feature_id \n";
    $from_part   = $from_part ?
            "$from_part join all_feature_names afn using (feature_id) "
          : "all_feature_names afn ";

    my $alias_only_where;
    # There is no difference in the wildcard or non-wildcard call to 
    # the full-text search [LP]
    if ($self->fulltext) {
        $alias_only_where = "where afn.searchable_name @@ to_tsquery(?)";
    }
    elsif ($wildcard) {
        $alias_only_where = "where lower(afn.name) like ?";
    }
    else {
        $alias_only_where = "where lower(afn.name) = ?";
    }

    $where_part = $where_part ?
                    "$alias_only_where $where_part"
                  : $alias_only_where;

   }
   else { #need to use the synonym table
    $select_part = "select distinct fs.feature_id \n";
    $from_part   = $from_part ?
            "$from_part join feature_synonym fs using (feature_id), synonym s " 
          : "feature_synonym fs, synonym s ";

    my $alias_only_where;
    # Again, with full-text there's no difference in wildcard/non-wildcard [LP]
    if ($self->fulltext) {
        $alias_only_where = "where fs.synonym_id = s.synonym_id and\n"
                   . "s.searchable_synonym_sgml @@ to_tsquery(?)";
    }
    elsif ($wildcard) {
        $alias_only_where  = "where fs.synonym_id = s.synonym_id and\n"
                   . "lower(s.synonym_sgml) like ?";
    }
    else {
        $alias_only_where  = "where fs.synonym_id = s.synonym_id and\n"
                   . "lower(s.synonym_sgml) = ?";
    }


    $where_part = $where_part ?
                    "$alias_only_where $where_part"
                  : $alias_only_where;
   }
  }
  else { #searching by name only
    $select_part = "select f.feature_id ";
    $from_part   = " feature f ";

    my $name_only_where;
    # Using full text search we only need create one WHERE clause, regardless of
    # the presence of any wildcards... [LP]
    if ($self->fulltext) {
        $name_only_where = "where f.searchable_name @@ to_tsquery(?)";
    }
    elsif ($wildcard) {
        $name_only_where = "where lower(f.name) like ?";
    }
    else {
        $name_only_where = "where lower(f.name) = ?";
    }


    $where_part = $where_part ?
                    "$name_only_where $where_part" 
                  : $name_only_where;
  }

  my $query = $select_part . ' FROM ' . $from_part . $where_part;

  # Added at suggestion of James Ward to strip confusing/fatal whitespace,
  # so we trim leading and trailing whitespace before processing query [LP]
  $query =~ s/^[ \t\r\n]+|[ \t\r\n]$//g;


  warn "first get_feature_by_name query:$query" if DEBUG;

  $sth = $self->dbh->prepare($query);

  if ($wildcard) {
    $name = $self->_search_name_prep($name);
    warn "name after protecting _ and % in the string:$name\n" if DEBUG;
  }

# what the hell happened to the lower casing!!!
# left over bug from making the adaptor case insensitive?

  #$name = lc($name);
  
  $sth->execute(lc($name)) or $self->throw("getting the feature_ids failed");

# this makes performance awful!  It does a wildcard search on a view
# that has several selects in it.  For any reasonably sized database,
# this won't work.
#
#  if ($sth->rows < 1 and 
#      $class ne 'chromosome' and
#      $class ne 'region' and
#      $class ne 'contig') {  
#
#    my $query;
#    ($name,$query) = $self->_complex_search($name,$class,$wildcard);
#
#    warn "complex_search query:$query\n";
#
#    $sth = $self->dbh->prepare($query);
#    $sth->execute($name) or $self->throw("getting the feature_ids failed");
#
#  }


     # prepare sql queries for use in while loops

  my $isth =  $self->dbh->prepare("
       select f.feature_id, f.name, f.type_id,f.uniquename,af.significance as score,
              fl.fmin,fl.fmax,fl.strand,fl.phase, fl.srcfeature_id, fd.dbxref_id,
              f.is_obsolete,f.seqlen
       from feature f join featureloc fl using (feature_id)
            left join analysisfeature af using (feature_id)
            left join feature_dbxref fd using (feature_id) 
       where
         f.feature_id = ? and fl.rank=0 and 
         (fd.dbxref_id is null or fd.dbxref_id in
          (select dbxref_id from dbxref where db_id = ?))
       order by fl.srcfeature_id
        ");

  my $jsth = $self->dbh->prepare("select name from feature
                                      where feature_id = ?");

    # getting feature info
  while (my $feature_id_ref = $sth->fetchrow_hashref) {

    warn "feature_id in features method loop:".$$feature_id_ref{feature_id} if DEBUG;

    $isth->execute($$feature_id_ref{'feature_id'},$self->gff_source_db_id)
             or $self->throw("getting feature info failed");

    if ($isth->rows == 0) { #this might be a srcfeature

      warn "$name might be a srcfeature" if DEBUG;

      my $is_srcfeature_query = $self->dbh->prepare("
         select srcfeature_id from featureloc where srcfeature_id=? limit 1
      ");
      $is_srcfeature_query->execute($$feature_id_ref{'feature_id'})
             or $self->throw("checking if feature is a srcfeature failed");

      $sth->finish;
      $isth->finish;
      $jsth->finish;
      if ($is_srcfeature_query->rows == 1) {#yep, its a srcfeature
          #build a feature out of the srcfeature:
          warn "Yep, $name is a srcfeature" if DEBUG;

          my @args = ($name) ;
          push @args, $base_start if $base_start;
          push @args, $stop if $stop;

            warn "srcfeature args:$args[0]" if DEBUG;

          my @seg = ($self->segment(@args));           

          $is_srcfeature_query->finish;
          return @seg;
      }
      else {
          $is_srcfeature_query->finish;
          return; #I got nothing!
      }
    }

      #getting chromosome info
    my $old_srcfeature_id=-1;
    my $parent_segment;
    while (my $hashref = $isth->fetchrow_hashref) {

      next if ($$hashref{'is_obsolete'} and !$self->allow_obsolete);

      if ($self->refclass && $$hashref{type_id} == $self->refclass) {
          #this feature is supposed to be a reference feature
          my $f = Bio::DB::Das::Chado::Segment->new($$hashref{'name'},
                                                    $self,
                                                    1,$$hashref{'seqlen'},
                                                    $$hashref{'uniquename'},
                                                    undef,
                                                    $$hashref{'feature_id'},
                                                    undef);
          push @features,$f;
          next;
      }

      if ($$hashref{'srcfeature_id'} != $old_srcfeature_id) {
        $jsth->execute($$hashref{'srcfeature_id'})
                 or die ("getting assembly info failed");
        my $src_name = $jsth->fetchrow_hashref;
        warn "src_name:$$src_name{'name'}" if DEBUG;
        $parent_segment =
             Bio::DB::Das::Chado::Segment->new($$src_name{'name'},$self,undef,undef,undef,undef,$$hashref{'srcfeature_id'});
        $old_srcfeature_id=$$hashref{'srcfeature_id'};
      }
        #now build the feature

      #Recursive Mapping
      if ($self->{recursivMapping}){
      #Fetch the recursively mapped  position

        my $sql = "select fl.fmin,fl.fmax,fl.strand,fl.phase
                   from feat_remapping(?)  fl
                   where fl.rank=0";
        my $recurs_sth =  $self->dbh->prepare($sql);
        $sql =~ s/\s+/ /gs ;
        $recurs_sth->execute($$feature_id_ref{'feature_id'});
        my $hashref2 = $recurs_sth->fetchrow_hashref;
        my $strand_ = $$hashref{'strand'};
        my $phase_ = $$hashref{'phase'};
        my $fmax_ = $$hashref{'fmax'};
        my $interbase_start;

      #If unable to recursively map we assume that the feature is
      # already mapped on the lowest refseq

        if ($recurs_sth->rows != 0){
          $interbase_start = $$hashref2{'fmin'};
          $strand_ = $$hashref2{'strand'};
          $phase_ = $$hashref2{'phase'};
          $fmax_ = $$hashref2{'fmax'};
        }else{
          $interbase_start = $$hashref{'fmin'};
        }
        $base_start = $interbase_start +1;

        my $type_obj =  Bio::DB::GFF::Typename->new(
                     $self->term2name($$hashref{type_id}),
                     $self->dbxref2source($$hashref{dbxref_id}) || "");

        my $feat = Bio::DB::Das::Chado::Segment::Feature->new(
                                        $self,
                                        $parent_segment,
                                        $parent_segment->seq_id,
                                        $base_start,$fmax_,
                                        $self->term2name($$hashref{'type_id'}),
                                        $$hashref{'score'},
                                        $strand_,
                                        $phase_,
                                        $$hashref{'name'},
                                        $$hashref{'uniquename'},
                                        $$hashref{'feature_id'}
                                                               );
        push @features, $feat;
        $recurs_sth->finish;
        #END Recursive Mapping
      } else {
     
        if ($class && $class eq 'CDS' && $self->inferCDS) {
            #$hashref holds info for the polypeptide
            my $poly_min = $$hashref{'fmin'};
            my $poly_max = $$hashref{'fmax'};
            my $poly_fid = $$hashref{'feature_id'};

            #get fid of parent transcript
            my $id_list = ref $self->term2name('derives_from') eq 'ARRAY' 
                        ? "in (".join(",",@{$self->term2name('derives_from')}).")"
                        : "= ".$self->term2name('derives_from');

            my $transcript_query = $self->dbh->prepare("
                SELECT object_id FROM feature_relationship
                WHERE type_id ".$id_list
                ." AND subject_id = $poly_fid"
            );

            $transcript_query->execute;
            my ($trans_id) = $transcript_query->fetchrow_array; 

            $id_list = ref $self->term2name('part_of') eq 'ARRAY'
                        ? "in (".join(",",@{$self->term2name('part_of')}).")"
                        : "= ".$self->term2name('part_of');

            #now get exons that are part of the transcript
            my $exon_query = $self->dbh->prepare("
               SELECT f.feature_id,f.name,f.type_id,f.uniquename,
                      af.significance as score,fl.fmin,fl.fmax,fl.strand,
                      fl.phase, fl.srcfeature_id, fd.dbxref_id,f.is_obsolete
               FROM feature f join featureloc fl using (feature_id)
                    left join analysisfeature af using (feature_id)
                    left join feature_dbxref fd using (feature_id)
               WHERE
                   f.type_id = ".$self->term2name('exon')." and f.feature_id in
                     (select subject_id from feature_relationship where object_id = $trans_id and
                             type_id ".$id_list." ) and 
                   fl.rank=0 and
                   (fd.dbxref_id is null or fd.dbxref_id in
                     (select dbxref_id from dbxref where db_id =".$self->gff_source_db_id."))        
            ");

            $exon_query->execute();

            while (my $exonref = $exon_query->fetchrow_hashref) {
                next if ($$exonref{fmax} < $poly_min);
                next if ($$exonref{fmin} > $poly_max);
                next if ($$exonref{is_obsolete} and !$self->allow_obsolete);

                my ($start,$stop);
                if ($$exonref{fmin} <= $poly_min && $$exonref{fmax} >= $poly_max) {
                    #the exon starts before polypeptide start
                    $start = $poly_min +1; 
                }
                else {
                    $start = $$exonref{fmin} +1;
                }

                if ($$exonref{fmax} >= $poly_max && $$exonref{fmin} <= $poly_min) {
                    $stop = $poly_max;
                }
                else {
                    $stop = $$exonref{fmax};
                }

                my $type_obj = Bio::DB::GFF::Typename->new(
                     'CDS',
                     $self->dbxref2source($$hashref{'dbxref_id'}) || '');


                        my $feat = Bio::DB::Das::Chado::Segment::Feature->new(
                                        $self,
                                        $parent_segment,
                                        $parent_segment->seq_id,
                                        $start,$stop,
                                        $type_obj,
                                        $$hashref{'score'},
                                        $$hashref{'strand'},
                                        $$hashref{'phase'},
                                        $$hashref{'name'},
                                        $$hashref{'uniquename'},
                                        $$hashref{'feature_id'}
                                                               );
                        push @features, $feat;
            }
            $exon_query->finish;
            $transcript_query->finish;
        }
        else {
         #the normal case where you don't infer CDS features 
            my $interbase_start = $$hashref{'fmin'};
            $base_start = $interbase_start +1;

            my $type_obj = Bio::DB::GFF::Typename->new(
                   $self->term2name($$hashref{'type_id'}),
                   $self->dbxref2source($$hashref{'dbxref_id'}) || '');

            my $srcf = 1 if ($self->refclass() == $$hashref{'type_id'}) ;
            
            my $feat = Bio::DB::Das::Chado::Segment::Feature->new(
                                        $self,
                                        $srcf ? '' : $parent_segment,
                                        $srcf ? '' : $parent_segment->seq_id,
                                        $base_start,$$hashref{'fmax'},
                                        $type_obj,
                                        $$hashref{'score'},
                                        $$hashref{'strand'},
                                        $$hashref{'phase'},
                                        $$hashref{'name'},
                                        $$hashref{'uniquename'},
                                        $$hashref{'feature_id'}
                                                               );

            push @features, $feat;
        }
      } 
    }
  }
  $sth->finish;
  $isth->finish;
  $jsth->finish;
  return @features;
}

# Handle spaces in search query; we need to avoid replacing 
# ' & ' with ' & & & ', though... [LP]
sub _search_name_prep_spaces {
    my $self = shift;
    my $name = shift;

    $name =~ s/\s&\s/ /g;   # Replace any user-defined ' & ' with spaces...
    $name =~ s/\s/ & /g;    # then replace all spaces with ' & '

    return $name;
}


*fetch_feature_by_name = \&get_feature_by_name; 

sub get_feature_by_feature_id {
  my $self = shift;
  my $f_id = shift;

  my @features = $self->features(-feature_id => $f_id);
  return @features;
}

sub get_feature_by_id {
  my $self = shift;
  my $f_id = shift;

  my @features = $self->features(-feature_id => $f_id);
  return $features[0];
}

*fetch = *get_feature_by_primary_id = \&get_feature_by_feature_id;

sub _complex_search {
    my $self = shift;
    my $name = shift;
    my $class= shift;

    warn "name before wildcard subs:$name\n" if DEBUG;

    $name = "\%$name" unless (0 == index($name, "%"));
    $name = "$name%"  unless (0 == index(reverse($name), "%"));

    warn "name after wildcard subs:$name\n" if DEBUG;

    my $select_part = "select ga.feature_id ";
    my $from_part   = "from gffatts ga ";
    my $where_part  = "where lower(ga.attribute) like ? ";
                                                                                                                          
    if ($class) {
        my $type    = $self->name2term($class);
        return unless $type;
        $from_part .= ", feature f ";
        $where_part.= "and ga.feature_id = f.feature_id and "
                     ."f.type_id = $type";
    }

    $where_part .= " and organism_id = ".$self->organism_id 
        if $self->organism_id;
 
    my $query = $select_part . $from_part . $where_part;
    return ($name, $query);
}

sub _search_name_prep {
  my $self = shift;
  my $name = shift;

  if ($self->fulltext) {

  # For full-text search, the appropriate extension wildcard
  # is ':*' for prefix-matching.  There are limitations to 
  # full-text search in that we cannot find internal parts of
  # words, so wildcards can only come at the ends of phrases/
  # lexemes.  Internal * are converted by tsquery into & [LP]
    $name =~ s/_/\\_/g;             # escape underscores in name
    $name =~ s/(?<=\s)\*//g;        # lose prefix wildcards (word start)
    $name =~ s/(?<=^)\*//g;         # lose prefix wildcards (query start)
    $name =~ s/\*(?=$)/:\*/g;       # convert trailing * (query end) into :*
    $name =~ s/\*(?=\s)/:\*/g;      # convert trailing * (word end) into :*

  }
  else {
    $name =~ s/_/\\_/g;  # escape underscores in name
    $name =~ s/\%/\\%/g; # ditto for percent signs

    $name =~ s/\*/%/g;
  }

  return $name;
}


=head2 srcfeature2name

returns a srcfeature name given a srcfeature_id

=cut

sub srcfeature2name {
    my $self = shift;
    my $id   = shift;

    return $self->{'srcfeature_id'}->{$id} if $self->{'srcfeature_id'}->{$id};

    my $sth = $self->dbh->prepare("select name from feature "
                                 ."where feature_id = ?");
    $sth->execute($id);

    my $hashref = $sth->fetchrow_hashref;
    $self->{'srcfeature_id'}->{$id} = $$hashref{'name'};

    $sth->finish;
    return $self->{'srcfeature_id'}->{$id};
}

=head2 gff_source_db_id

  Title   : gff_source_db_id
  Function: caches the chado db_id from the chado db table

=cut

sub gff_source_db_id {
    my $self = shift;
    return $self->{'gff_source_db_id'} if $self->{'gff_source_db_id'};

    my $sth = $self->dbh->prepare("
       select db_id from db
       where name = 'GFF_source'");
    $sth->execute();

    my $hashref = $sth->fetchrow_hashref;
    $self->{'gff_source_db_id'} = $$hashref{'db_id'}; 

    $sth->finish;
    return $self->{'gff_source_db_id'};
}

=head2 gff_source_dbxref_id

Gets dbxref_id for features that have a gff source associated

=cut

sub source2dbxref {
    my $self   = shift;
    my $source = shift;

    #Why was this here?  Debugging?
    #return 'fake' unless defined($self->gff_source_db_id);

    return $self->{'source_dbxref'}->{$source}
        if $self->{'source_dbxref'}->{$source};

    my $sth = $self->dbh->prepare("
        select dbxref_id,accession from dbxref where db_id= ?"
    );
    $sth->execute($self->gff_source_db_id);

    while (my $hashref = $sth->fetchrow_hashref) {
        warn "s2d:accession:$$hashref{accession}, dbxref_id:$$hashref{dbxref_id}\n" if DEBUG;

        $self->{'source_dbxref'}->{$$hashref{accession}} = $$hashref{dbxref_id};
        $self->{'dbxref_source'}->{$$hashref{dbxref_id}} = $$hashref{accession};
    } 

    $sth->finish;
    return $self->{'source_dbxref'}->{$source}; 
}

=head2 dbxref2source

returns the source (string) when given a dbxref_id

=cut

sub dbxref2source {
    my $self   = shift;
    my $dbxref = shift;

    return '.' unless defined($self->gff_source_db_id);

    warn "d2s:dbxref:$dbxref\n" if DEBUG;

    if (defined ($self->{'dbxref_source'}) && $dbxref
     && defined ($self->{'dbxref_source'}->{$dbxref})) {
        return $self->{'dbxref_source'}->{$dbxref};
    }

    my $sth = $self->dbh->prepare("
        select dbxref_id,accession from dbxref where db_id=?"
    );
    $sth->execute($self->gff_source_db_id);

    if  ($sth->rows < 1) {
        $sth->finish;
        return ".";
    }

    while (my $hashref = $sth->fetchrow_hashref) {
        warn "d2s:accession:$$hashref{accession}, dbxref_id:$$hashref{dbxref_id}\n"
            if DEBUG;

        $self->{'source_dbxref'}->{$$hashref{accession}} = $$hashref{dbxref_id};
        $self->{'dbxref_source'}->{$$hashref{dbxref_id}} = $$hashref{accession};
    }
                                                                       
    $sth->finish;
    if (defined $self->{'dbxref_source'} && $dbxref
           && defined $self->{'dbxref_source'}->{$dbxref}) {
        return $self->{'dbxref_source'}->{$dbxref};
    } else {
        $self->{'dbxref_source'}->{$dbxref} = "." if $dbxref;
        return ".";
    }
}

=head2 source_dbxref_list

 Title   : source_dbxref_list
 Usage   : @all_dbxref_ids = $db->source_dbxref_list()
 Function: Gets a list of all dbxref_ids that are used for GFF sources
 Returns : a comma delimited string that is a list of dbxref_ids
 Args    : none
 Status  : public

This method queries the database for all dbxref_ids that are used
to store GFF source terms.

=cut

sub source_dbxref_list {
    my $self = shift;
    return $self->{'source_dbxref_list'} if defined $self->{'source_dbxref_list'};

    my $query = "select dbxref_id from dbxref where db_id = ?";
    my $sth = $self->dbh->prepare($query);
    $sth->execute($self->gff_source_db_id);

    #unpack it here to make it easier
    my @dbxref_list;
    while (my $row = $sth->fetchrow_arrayref) {
        push @dbxref_list, $$row[0];
    }

    $sth->finish;
    $self->{'source_dbxref_list'} = join (",",@dbxref_list);
    return $self->{'source_dbxref_list'};
}


=head2 search_notes

 Title   : search_notes
 Usage   : $db->search_notes($search_term,$max_results)
 Function: full-text search on features, ENSEMBL-style
 Returns : an array of [$name,$description,$score]
 Args    : see below
 Status  : public

This routine performs a full-text search on feature attributes (which
attributes depend on implementation) and returns a list of
[$name,$description,$score], where $name is the feature ID (accession?),
$description is a human-readable description such as a locus line, and
$score is the match strength.

=cut

=head2 ** NOT YET ACTIVE: search_notes IS IN TESTING STAGE **

sub search_notes {
  my $self = shift;
  my ($search_string,$limit) = @_;
  my $limit_str;
  if (defined $limit) {
    $limit_str = " LIMIT $limit ";
  } else {
    $limit_str = "";
  } 

# so here's the plan:
# if there is only 1 word, do 1-3
#  1. search for accessions like $string.'%'--if any are found, quit and return them
#  2. search for feature.name like $string.'%'--if found, keep and continue
#  3. search somewhere in analysis like $string.'%'--if found, keep and continue
# if there is more than one word, don't search accessions
#  4. search each word anded together like '%'.$string.'%' --if found, keep and continue
#  5. search somewhere in analysis like '%'.$string.'%'

#  $self->dbh->trace(1);

  my @search_str = split /\s+/, $search_string;
  my $qsearch_term = $self->dbh->quote($search_str[0]);
  my $like_str = "( (dbx.accession ~* $qsearch_term OR \n"
        ."           f.name        ~* $qsearch_term) ";
  for (my $i=1;$i<(scalar @search_str);$i++) {
    $qsearch_term = $self->dbh->quote($search_str[$i]);
    $like_str .= "and \n";
    $like_str .= "          (dbx.accession ~* $qsearch_term OR \n"
                ."           f.name        ~* $qsearch_term) ";
  } 
  $like_str .= ")";

  my $sth = $self->dbh->prepare("
     select dbx.accession,f.name,0 
     from feature f, dbxref dbx, feature_dbxref fd
     where
        f.feature_id = fd.feature_id and
        fd.dbxref_id = dbx.dbxref_id and 
        $like_str 
     $limit_str
    ");
  $sth->execute or throw ("couldn't execute keyword query");

  my @results;
  while (my ($acc, $name, $score) = $sth->fetchrow_array) {
    $score = sprintf("%.2f",$score);
    push @results, [$acc, $name, $score];
  }
  $sth->finish;
  return @results;
}

=cut

=head2 attributes

 Title   : attributes
 Usage   : @attributes = $db->attributes($id,$name)
 Function: get the "attributes" on a particular feature
 Returns : an array of string
 Args    : feature ID [, attribute name]
 Status  : public

This method is intended as a "work-alike" to Bio::DB::GFF's 
attributes method, which has the following returns:

Called in list context, it returns a list.  If called in a
scalar context, it returns the first value of the attribute
if an attribute name is provided, otherwise it returns a
hash reference in which the keys are attribute names
and the values are anonymous arrays containing the values.

=cut

sub attributes {
  my $self = shift;
  my ($id,$tag) = @_;

  #get feature_id

  my $query = "select feature_id from feature where uniquename = ?";
  $query .= " and organism_id = ".$self->organism_id if $self->organism_id;

  my $sth = $self->dbh->prepare($query);
  $sth->execute($id) or $self->throw("failed to get feature_id in attributes"); 
  my $hashref = $sth->fetchrow_hashref;
  my $feature_id = $$hashref{'feature_id'};

  if (defined $tag) {
    my $query = "SELECT attribute FROM gfffeatureatts(?) WHERE type = ?";
    $sth = $self->dbh->prepare($query);
    $sth->execute($feature_id,$tag);
  } else {
    my $query = "SELECT type,attribute FROM gfffeatureatts(?)"; 
    $sth = $self->dbh->prepare($query);
    $sth->execute($feature_id);
  }

  my $arrayref = $sth->fetchall_arrayref;

  my @array = @$arrayref;
  ($sth->finish && return ()) if scalar @array == 0;

## dgg; ugly patch to copy polypeptide/protein residues into 'translation' attribute
# need to add to gfffeatureatts ..
  if (!defined $tag || $tag eq 'translation') {
    $sth = $self->dbh->prepare("select type_id from feature where feature_id = ?");
    $sth->execute($feature_id); # or $self->throw("failed to get feature_id in attributes"); 
    $hashref = $sth->fetchrow_hashref;
    my $type_id = $$hashref{'type_id'};
    ## warn("DEBUG: dgg ugly prot. patch; type=$type_id for ftid=$feature_id\n");
    
    if(  $self->name2term('polypeptide') 
         && $type_id 
         && $type_id == $self->name2term('polypeptide') 
      || $self->name2term('protein') 
         && $type_id 
         && $type_id == $self->name2term('protein')
      ) {
      $sth = $self->dbh->prepare("select residues from feature where feature_id = ?");
      $sth->execute($feature_id); # or $self->throw("failed to get feature_id in attributes"); 
      $hashref = $sth->fetchrow_hashref;
      my $aa = $$hashref{'residues'};
      if($aa) {
    ## warn("DEBUG: dgg ugly prot. patch; aalen=",length($aa),"\n");
    ## this wasn't working till I added in a featureprop 'translation=dummy' .. why?
        if($tag) { push( @array, [ $aa]); }
        else { push( @array, ['translation', $aa]); }
        }
      }
  }
  
  my @result;
   foreach my $lineref (@array) {
      my @la = @$lineref;
      push @result, @la;
   }

  $sth->finish;
  return @result if wantarray;

  return $result[0] if $tag;

  my %result;

  foreach my $lineref (@array) {
    my ($key,$value) = splice(@$lineref,0,2);
    push @{$result{$key}},$value;
  }
  return \%result;

}



=head2 _segclass

 Title   : _segclass
 Usage   : $class = $db->_segclass
 Function: returns the perl class that we use for segment() calls
 Returns : a string containing the segment class
 Args    : none
 Status  : reserved for subclass use

=cut

#sub default_class {return 'Sequence' }
## URGI changes
sub default_class {

    my $self = shift;

#dgg 
    unless( $self->{'reference_class'} || @_ ) {
      $self->{'reference_class'} = $self->chado_reference_class();
      }
      
    if(@_) {
      my $checkref = $self->check_chado_reference_class(@_);
      unless($checkref) {
        $self->throw("unable to find reference_class '$_[0]' feature in the database");
        }
      }
      
    $self->{'reference_class'} = shift || 'Sequence' if(@_);

    return $self->{'reference_class'};

}

sub check_chado_reference_class {
  my $self = shift;
  if(@_) {
    my $refclass= shift;
    my $type_id = $self->name2term($refclass);
    my $query = "select feature_id from feature where type_id = ?";
    my $sth = $self->dbh->prepare($query);
    $sth->execute($type_id) or $self->throw("trying to find chado_reference_class");
    my $data = $sth->fetchrow_hashref();
    my $refid= $$data{'feature_id'};
    ## warn("check_chado_reference_class: $refclass = $type_id -> $refid"); # DEBUG

    $sth->finish;
    return $refid;
  }
}

=head2 chado_reference_class

  Title   : chado_reference_class 
  Usage   : $obj->chado_reference_class()
  Function: get or return the ID to use for Gbrowse map reference class 
            using cvtermprop table, value = MAP_REFERENCE_TYPE 
  Returns : the cvterm.name 
  Args    : to return the id, none; to determine the id, 1
  See also: default_class, refclass_feature_id

  Optionally test that user/config supplied ref class is indeed a proper
  chado feature type.
  
=cut


sub chado_reference_class {
  my $self = shift;
  return $self->{'chado_reference_class'} if($self->{'chado_reference_class'});

  my $chado_reference_class='Sequence'; # default ?
  
  my $query = "select cvterm_id from cvtermprop where value = ?";
  my $sth = $self->dbh->prepare($query);
  $sth->execute(MAP_REFERENCE_TYPE) or $self->throw("trying to find chado_reference_class");
  my $data = $sth->fetchrow_hashref(); #? FIXME: could be many values *?
  my $ref_cvtermid = $$data{'cvterm_id'};
 
  $sth->finish; 
  if($ref_cvtermid) {
    $query = "select name from cvterm where cvterm_id = ?";
    $sth = $self->dbh->prepare($query);
    $sth->execute($ref_cvtermid) or $self->throw("trying to find chado_reference_class");
    $data = $sth->fetchrow_hashref();
    $chado_reference_class = $$data{'name'} if ($$data{'name'});
    # warn("chado_reference_class: $chado_reference_class = $ref_cvtermid"); # DEBUG
    $sth->finish;
  }

  return $self->{'chado_reference_class'} = $chado_reference_class;
}


=head2 refclass_feature_id

 Title   : refclass_feature_id
 Usage   : $self->refclass_srcfeature_id()
 Function: Used to store the feature_id of the reference class feature we are working on (e.g. contig, supercontig)
           With this feature we can filter out all the request to be sure we are extracting a feature located on 
           the reference class feature.
 Returns : A scalar
 Args    : The feature_id on setting

=cut

sub refclass_feature_id {

    my $self = shift;

    $self->{'refclass_feature_id'} = shift if(@_);

    return $self->{'refclass_feature_id'};

}


sub _segclass { return SEGCLASS }

sub absolute {return}

#implemented exactly the same as Bio::DB::SeqFeature::Store::DBI::mysql
sub clone {
  #this is EO's implementation for the BDSFS::DBI::Pg implementation
  #he says Pg's clone method is flawed
    my $self = shift;

#    my $dsn  = $self->{db_args}->{dsn};
#    my $user = $self->{db_args}->{username};
#    my $pass = $self->{db_args}->{password};

#    $self->dbh()->{InactiveDestroy} = 1;
#    my $new_dbh = DBI->connect($dsn,$user,$pass) or $self->throw($DBI::errstr);
#    $new_dbh->{InactiveDestroy} = 1;
#    $self->{dbh} = $new_dbh unless $self->is_temp;


#  this is the BDSFS::DBI::mysql implementation
    $self->{dbh}{InactiveDestroy} = 1;
    $self->{dbh} = $self->{dbh}->clone({}) 
       #magic from perlmonks to silence a warning:
       # http://www.perlmonks.org/?node_id=594175
       # without the empty {} you get warnings about unrecognised attribute name
       ; # unless $self->is_temp;
}


#this sub doesn't work and just causes annoying warnings
#sub DESTROY {
#        my $self = shift;
#        $self->dbh->disconnect;
#        return;
#}

=head1 LEFTOVERS FROM BIO::DB::GFF NEEDED FOR DAS

these methods should probably be declared in an interface class
that Bio::DB::GFF implements.  for instance, the aggregator methods
could be described in Bio::SeqFeature::AggregatorI

=cut

sub aggregators { return(); }

=head1 END LEFTOVERS

=cut


package Bio::DB::Das::ChadoIterator;

sub new {
  my $package  = shift;
  my $features = shift;
  return bless $features,$package;
}

sub next_seq {
  my $self = shift;
  return unless @$self;
    my $next_feature = shift @$self;
  return $next_feature;
}

1;



