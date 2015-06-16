package ca3g::OverlapInCore;

require Exporter;

@ISA    = qw(Exporter);
@EXPORT = qw(overlapConfigure overlap overlapCheck);

use strict;

use File::Path qw(make_path remove_tree);

use ca3g::Defaults;
use ca3g::Execution;


sub overlapConfigure ($$$$) {
    my $WRK  = shift @_;
    my $wrk  = $WRK;
    my $asm  = shift @_;
    my $tag  = shift @_;
    my $type = shift @_;

    my $bin  = getBinDirectory();
    my $cmd;

    $wrk = "$wrk/correction"  if ($tag eq "cor");
    $wrk = "$wrk/trimming"    if ($tag eq "obt");

    my $path = "$wrk/1-overlapper";

    caFailure("invalid type '$type'", undef)  if (($type ne "partial") && ($type ne "normal"));

    if (-e "$path/overlap.sh") {
        my $numJobs = 0;
        open(F, "< $path/overlap.sh") or caExit("can't open '$path/overlap.sh' for reading: $!", undef);
        while (<F>) {
            $numJobs++  if (m/^\s+job=/);
        }
        close(F);
        print STDERR "--  Configured $numJobs overlapInCore jobs.\n";
    }

    return  if (skipStage($WRK, $asm, "$tag-overlapConfigure") == 1);
    return  if (-e "$path/ovljob.files");
    return  if (-e "$path/ovlopt");

    make_path("$path") if (! -d "$path");

    if (! -e "$path/$asm.partition.ovlopt") {

        #  These used to be runCA options, but were removed in ca3g.  They were used mostly for illumina-pacbio correction,
        #  but were also used (or could have been used) during the Salmon assembly when overlaps were computed differently
        #  depending on the libraries involved (and was run manually).  These are left in for documentation.
        #
        #my $checkLibrary       = getGlobal("${tag}CheckLibrary");
        #my $hashLibrary        = getGlobal("${tag}HashLibrary");
        #my $refLibrary         = getGlobal("${tag}RefLibrary");

        my $hashBlockLength = getGlobal("${tag}OvlHashBlockLength");
        my $hashBlockSize   = 0;
        my $refBlockSize    = getGlobal("${tag}OvlRefBlockSize");
        my $refBlockLength  = getGlobal("${tag}OvlRefBlockLength");

        if (($refBlockSize > 0) && ($refBlockLength > 0)) {
            caExit("can't set both ${tag}OvlRefBlockSize and ${tag}OvlRefBlockLength", undef);
        }

        print STDERR "PARTITION for '$tag'\n";

        $cmd  = "$bin/overlapInCorePartition \\\n";
        $cmd .= " -g  $wrk/$asm.gkpStore \\\n";
        $cmd .= " -bl $hashBlockLength \\\n";
        $cmd .= " -bs $hashBlockSize \\\n";
        $cmd .= " -rs $refBlockSize \\\n";
        $cmd .= " -rl $refBlockLength \\\n";
        #$cmd .= " -H $hashLibrary \\\n" if ($hashLibrary ne "0");
        #$cmd .= " -R $refLibrary \\\n"  if ($refLibrary ne "0");
        #$cmd .= " -C \\\n" if (!$checkLibrary);
        $cmd .= " -o  $path/$asm.partition \\\n";
        $cmd .= "> $path/$asm.partition.err 2>&1";

        if (runCommand($wrk, $cmd)) {
            caExit("failed partition for overlapper", undef);
        }
    }

    open(BAT, "< $path/$asm.partition.ovlbat") or caExit("can't open '$path/$asm.partition.ovlbat' for reading: $!", undef);
    open(JOB, "< $path/$asm.partition.ovljob") or caExit("can't open '$path/$asm.partition.ovljob' for reading: $!", undef);
    open(OPT, "< $path/$asm.partition.ovlopt") or caExit("can't open '$path/$asm.partition.ovlopt' for reading: $!", undef);

    my @bat = <BAT>;  chomp @bat;
    my @job = <JOB>;  chomp @job;
    my @opt = <OPT>;  chomp @opt;

    close(BAT);
    close(JOB);
    close(OPT);

    if (! -e "$path/overlap.sh") {
        my $merSize      = getGlobal("${tag}OvlMerSize");
        
        #my $hashLibrary  = getGlobal("${tag}OvlHashLibrary");
        #my $refLibrary   = getGlobal("${tag}OvlRefLibrary");
        
        #  Create a script to run overlaps.  We make a giant job array for this -- we need to know
        #  hashBeg, hashEnd, refBeg and refEnd -- from that we compute batchName and jobName.

        my $hashBits       = getGlobal("${tag}OvlHashBits");
        my $hashLoad       = getGlobal("${tag}OvlHashLoad");

        my $taskID            = getGlobal("gridEngineTaskID");
        my $submitTaskID      = getGlobal("gridEngineArraySubmitID");

        open(F, "> $path/overlap.sh") or caExit("can't open '$path/overlap.sh' for writing: $!", undef);
        print F "#!" . getGlobal("shell") . "\n";
        print F "\n";
        print F "perl='/usr/bin/env perl'\n";
        print F "\n";
        print F "jobid=$taskID\n";
        print F "if [ x\$jobid = x -o x\$jobid = xundefined -o x\$jobid = x0 ]; then\n";
        print F "  jobid=\$1\n";
        print F "fi\n";
        print F "if [ x\$jobid = x ]; then\n";
        print F "  echo Error: I need $taskID set, or a job index on the command line.\n";
        print F "  exit 1\n";
        print F "fi\n";
        print F "\n";

        for (my $ii=1; $ii<=scalar(@bat); $ii++) {
            print F "if [ \$jobid -eq $ii ] ; then\n";
            print F "  bat=\"$bat[$ii-1]\"\n";            #  Needed to mkdir.
            print F "  job=\"$bat[$ii-1]/$job[$ii-1]\"\n";  #  Needed to simplify overlapCheck() below.
            print F "  opt=\"$opt[$ii-1]\"\n";
            print F "fi\n";
            print F "\n";
        }

        print F "\n";
        print F "if [ ! -d $path/\$bat ]; then\n";
        print F "  mkdir $path/\$bat\n";
        print F "fi\n";
        print F "\n";
        print F "if [ -e $path/\$job.ovb.gz ]; then\n";
        print F "  echo Job previously completed successfully.\n";
        print F "  exit\n";
        print F "fi\n";
        print F "\n";

        print F getBinDirectoryShellCode();

        print F "\$bin/overlapInCore \\\n";
        print F "  -G \\\n"  if ($type eq "partial");
        print F "  -t ", getGlobal("${tag}OvlThreads"), " \\\n";
        print F "  -k $merSize \\\n";
        print F "  -k $wrk/0-mercounts/$asm.ms$merSize.frequentMers.fasta \\\n";
        print F "  --hashbits $hashBits \\\n";
        print F "  --hashload $hashLoad \\\n";
        print F "  --maxerate  ", getGlobal("${tag}OvlErrorRate"), " \\\n";
        print F "  --minlength ", getGlobal("minOverlapLength"), " \\\n";
        print F "  \$opt \\\n";
        print F "  -o $path/\$job.ovb.WORKING.gz \\\n";
        #print F "  -H $hashLibrary \\\n" if ($hashLibrary ne "0");
        #print F "  -R $refLibrary \\\n"  if ($refLibrary  ne "0");
        print F "  $wrk/$asm.gkpStore \\\n";
        print F "&& \\\n";
        print F "mv $path/\$job.ovb.WORKING.gz $path/\$job.ovb.gz\n";
        print F "\n";
        print F "exit 0\n";
        close(F);

        system("chmod +x $path/overlap.sh");
    }

    my $jobs      = scalar(@job);
    my $batchName = $bat[$jobs-1];  chomp $batchName;
    my $jobName   = $job[$jobs-1];  chomp $jobName;

    print STDERR "Created $jobs overlap jobs.  Last batch '$batchName', last job '$jobName'.\n";

    stopAfter("overlap-configure");
}




#  Check that the overlapper jobs properly executed.  If not,
#  complain, but don't help the user fix things.
#
sub overlapCheck ($$$$$) {
    my $WRK     = shift @_;
    my $wrk     = $WRK;
    my $asm     = shift @_;
    my $tag     = shift @_;
    my $type    = shift @_;
    my $attempt = shift @_;

    $wrk = "$wrk/correction"  if ($tag eq "cor");
    $wrk = "$wrk/trimming"    if ($tag eq "obt");

    my $path    = "$wrk/1-overlapper";

    if ((-e "$path/ovljob.files") && ($attempt == 3)) {
        my $results = 0;
        open(F, "< $path/ovljob.files") or caExit("can't open '$path/ovljob.files' for reading: $!\n", undef);
        while (<F>) {
            $results++;
        }
        close(F);
        print STDERR "--  Found $results overlapInCore output files.\n";
    }

    return  if (skipStage($WRK, $asm, "$tag-overlapCheck", $attempt) == 1);
    return  if (-e "$path/ovljob.files");

    my $currentJobID   = 1;
    my @successJobs;
    my @failedJobs;
    my $failureMessage = "";

    open(F, "< $path/overlap.sh") or caExit("can't open '$path/overlap.sh' for reading: $!", undef);

    while (<F>) {
        if (m/^\s+job=\"(\d+\/\d+)\"$/) {
            if      (-e "$path/$1.ovb.gz") {
                push @successJobs, "$path/$1.ovb.gz\n";
                
            } elsif (-e "$path/$1.ovb") {
                push @successJobs, "$path/$1.ovb\n";
                
            } elsif (-e "$path/$1.ovb.bz2") {
                push @successJobs, "$path/$1.ovb.bz2\n";
                
            } elsif (-e "$path/$1.ovb.xz") {
                push @successJobs, "$path/$1.ovb.xz\n";
                
            } else {
                $failureMessage .= "  job $path/$1 FAILED.\n";
                push @failedJobs, $currentJobID;
            }

            $currentJobID++;
        }
    }

    close(F);

    #  No failed jobs?  Success!

    if (scalar(@failedJobs) == 0) {
        open(L, "> $path/ovljob.files") or caExit("can't open '$path/ovljob.files' for writing: $!", undef);
        print L @successJobs;
        close(L);
        setGlobal("ca3gIteration", 0);
        emitStage($WRK, $asm, "$tag-overlapCheck");
        return;
    }

    #  If not the first attempt, report the jobs that failed, and that we're recomputing.

    if ($attempt > 1) {
        print STDERR "\n";
        print STDERR scalar(@failedJobs), " overlapper jobs failed:\n";
        print STDERR $failureMessage;
        print STDERR "\n";
    }

    #  If too many attempts, give up.

    if ($attempt > 2) {
        caExit("failed to overlap.  Made " . ($attempt-1) . " attempts, jobs still failed", undef);
    }

    #  Otherwise, run some jobs.

    print STDERR "overlapCheck() -- attempt $attempt begins with ", scalar(@successJobs), " finished, and ", scalar(@failedJobs), " to compute.\n";

    emitStage($WRK, $asm, "$tag-overlapCheck", $attempt);

    submitOrRunParallelJob($wrk, $asm, "${tag}ovl", $path, "overlap", @failedJobs);
}

