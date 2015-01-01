#!/usr/bin/perl -w
# Copyright © 2011-2013 Jamie Zawinski <jwz@jwz.org>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or 
# implied warranty.
#
# Examines the frames in a video and tells you whether the aspect ratio of
# the video itself differs from that of the video's imagery: that is, it
# will tell you if you have a 4:3 video with a letterboxed 16:9 inside it,
# with black stripes hardcoded into the images.
#
# You don't want that, because if you display a 4:3 video on a 16:9 screen,
# and it's really a 16:9 video inside, it will have black stripes on all
# sides (the hardcoded stripes at the top and bottom, plus the display-added
# stripes on the left and right.)
#
# Requires either: "HandBrakeCLI"; or "mplayer" plus "convert" (ImageMagick).
#
# Using "HandBrakeCLI" relies on HandBrake's internal bounding-box detection.
# Using "mplayer" gives you more options on bounding-box detection, but works
# very poorly becauses mplayer sucks.  Very often, it will get stuck in a loop
# decoding the same frame forever.
#
# Created:  4-Jun-2011.


# Good choices for cropping and re-encoding the video:
#
# -  HandBrakeCLI
#     --encoder x264
#     --x264opts
#       cabac=0:ref=2:me=umh:bframes=0:weightp=0:8x8dct=0:trellis=0:subme=6
#     --quality 17.75
#     --aencoder faac,copy:ac3
#     --ab 160,160
#     --arate Auto,Auto
#     --previews 30
#     --loose-anamorphic
#     --modulus 16
#
#    Handbrake is pretty good at guessing the crop area automatically.
#    It does this by looking at the N preview images specified above.
#    If it guesses wrong, specify it with --crop <T:B:L:R>
#
#    Those x264opts are what Handbrake says is "universally compatible
#    for all current Apple devices", as of 2011.
#
#
# -  MPEG Streamclip
#    Type in the crop numbers manually.
#    H.264 at Quality = 65% is a good choice.
#


require 5;
use diagnostics;
use strict;

my $progname = $0; $progname =~ s@.*/@@g;
my $version = q{ $Revision: 1.6 $ }; $version =~ s/^[^\d]+([\d.]+).*/$1/;

my $verbose = 0;

my $rm_minus_rf = undef;
END { system ("rm", "-rf", $rm_minus_rf) if $rm_minus_rf; }


sub safe_system(@) {
  my @cmd = @_;
  system (@cmd);
  my $exit_value  = $? >> 8;
  my $signal_num  = $? & 127;
  my $dumped_core = $? & 128;
  error ("$cmd[0]: core dumped!") if ($dumped_core);
  error ("$cmd[0]: signal $signal_num!") if ($signal_num);
  error ("$cmd[0]: exited with $exit_value!") if ($exit_value);
}


# returns the full path of the named program, or undef.
#
sub which($) {
  my ($prog) = @_;
  return $prog if ($prog =~ m@^/@s && -x $prog);
  foreach (split (/:/, $ENV{PATH})) {
    return $prog if (-x "$_/$prog");
  }
  return undef;
}


sub extract_frames($$$$) {
  my ($file, $start_sec, $end_sec, $frame_rate) = @_;

  my $fn = $file;
  $fn =~ s@^.*/@@s;

  my $dir = sprintf ("%s/vbbox.%08x",
                     ($ENV{TMPDIR} ? $ENV{TMPDIR} : "/tmp"),
                     rand(0xFFFFFFFF));
  $dir =~ s@//+@/@gs;

  $rm_minus_rf = $dir;			# nuke it even at abnormal exits.
  system ("rm", "-rf", $rm_minus_rf);

  print STDERR "$progname: $fn: creating tmp dir: $dir\n" if ($verbose);
  mkdir ($dir);

  my $ff = $file;
  $ff =~ s@([^-_.a-z\d/])@\\$1@gsi;
  my @cmd = ("mplayer",
             "-quiet", "-really-quiet",
             "-nosound",
             "-vo", "pnm:outdir=$dir",
             "-ss",     $start_sec,
            #"-endpos", $end_sec,
             "-sstep",  $frame_rate,
             $ff);
  my $cmd = join (' ', @cmd);
  print STDERR "$progname: exec: $cmd\n" if ($verbose);

  # This does not work to detect a stuck/looping mplayer, WTF.
#  my $cpu_secs = 20;
#  $cmd = "ulimit -t $cpu_secs; $cmd";

  # Fucking mplayer won't shut up even with "-quiet -really-quiet".
  $cmd = "$cmd >/dev/null 2>&1";

  safe_system ($cmd);

  return $dir;
}


sub scan_frames($$$$$$) {
  my ($file, $dir, $fuzz, $xoff, $yoff, $edit_p) = @_;

  my $fn = $file;
  $fn =~ s@^.*/@@s;

  my ($maxw, $maxh, $minx, $miny) = (0, 0, 9999999, 99999999);

  opendir (my $dh, $dir) || error ("$dir: $!");
  my @files = ();
  foreach (readdir ($dh)) {
    push @files, $_ unless m/^\./s;
  }
  closedir $dh;

  # Ignore the last couple frames.
  pop @files if ($#files > 1);
  pop @files if ($#files > 1);

  if ($#files <= 0) {
    print STDERR "$progname: $file: no frames, too short?\n";
    system ("rm", "-rf", $rm_minus_rf);
    $rm_minus_rf = undef;
    system ("open", "-a", "MPEG Streamclip", $file) if ($edit_p);
    return;
  }

  # Find size of some frame.
  my $cmd = "convert $dir/" . $files[0] . " -format '%w %h' info:-";
  my $size = `$cmd`;
  my ($ow, $oh) = split(' ', $size);
  print STDERR "$progname: $fn: orig size: ${ow}x${oh}\n" if ($verbose > 1);

  foreach my $out (@files) {
    my $oo = $out;
    $out = "$dir/$out";
    my @cmd = ("convert", 
               $out,
               "-shave", "${xoff}x${yoff}",
#              "-blur",  $blur,
               "-fuzz",  $fuzz,
               "-trim",
               "-format", "%wx%h%O",
               "info:-");
    my $cmd = join (' ', @cmd);
    print STDERR "$progname: exec: $cmd\n" if ($verbose > 2);
    my $size = `$cmd 2>/dev/null`;
    my ($w, $h, $x, $y) = ($size =~ m/^(\d+)x(\d+)\+(\d+)\+(\d+)$/);
    if (! defined($y) || $w < 10) {
      print STDERR "$progname: $out: blank\n" if ($verbose > 1);
    } else {
      $x += $xoff;
      $y += $yoff;
      my $x2 = $ow - ($x + $w);
      my $y2 = $oh - ($y + $h);
      print STDERR "$progname: $oo margin: $y $x2 $y2 $x\n" if ($verbose > 1);

#      safe_system ("convert $out -blur $blur -crop ${w}x${h}+${x}+${y} /tmp/$oo.png");

      $maxw = $w if ($w > $maxw);
      $maxh = $h if ($h > $maxh);
      $minx = $x if ($x < $minx);
      $miny = $y if ($y < $miny);
    }
    unlink $out;
  }

  my $x2 = $ow - ($minx + $maxw);
  my $y2 = $oh - ($miny + $maxh);

  return ($ow, $oh, $maxw, $maxh, $miny, $minx, $y2, $x2);
}



sub bbox_mplayer($$) {
  my ($file, $edit_p) = @_;

  my $start_sec     = 10;	# start at N seconds
  my $end_sec       = 90;	# end at N seconds (doesn't work)
  my $frame_rate    = 10;	# one frame every N seconds
  my $blur          = "0x5";	# blur image before comparing
  my $fuzz          = "10%";	# color comparison slack
  my ($xoff, $yoff) = (0, 0);	# lose N pixels from each edge first

  my $dir = extract_frames ($file, $start_sec, $end_sec, $frame_rate);
  my @ret = scan_frames ($file, $dir, $fuzz, $xoff, $yoff, $edit_p);
  system ("rm", "-rf", $dir);
  return @ret;
}


# Here's another way to do it...
#
sub bbox_handbrake($) {
  my ($file) = @_;

  my $ff = $file;
  $ff =~ s@([^-_.a-z\d/])@\\$1@gsi;
  my @cmd = ("HandBrakeCLI", "--scan", "--previews", "30", "-i", $ff);
  my $cmd = join (' ', @cmd);
  print STDERR "$progname: exec: $cmd\n" if ($verbose);
  my $ret = `( $cmd ) 2>&1`;

  my ($ow, $oh) = ($ret =~ m@scan: .*, (\d+)x(\d+), @s);
  my ($y, $y2, $x, $x2) = ($ret =~ m@, autocrop = (\d+)/(\d+)/(\d+)/(\d+), @s);

  return () unless defined($x2);

  my $nw = $ow - $x - $x2;
  my $nh = $oh - $y - $y2;
  return ($ow, $oh, $nw, $nh, $y, $x, $y2, $x2);
}


sub bbox($$) {
  my ($file, $edit_p) = @_;

  $file =~ s@//+@/@gs;

  my @R;
  if    (which ("HandBrakeCLI")) { @R = bbox_handbrake ($file); }
  elsif (which ("mplayer"))      { @R = bbox_mplayer ($file, $edit_p); }
  else { error ("neither HandBrakeCLI nor mplayer found on \$PATH.");  }

  my ($ow, $oh, $maxw, $maxh, $miny, $minx, $y2, $x2) = @R;

  if (!defined($x2)) {
    print STDERR "$progname: $file: unknown\n";
  } else {
    my $oaspect = sprintf ("%.2f", $ow / $oh);
    my $naspect = $maxh ? sprintf ("%.2f", $maxw / $maxh) : "0.00";

    if ($naspect > $oaspect + 0.01 ||
        $naspect < $oaspect - 0.01) {
      print STDERR "$progname: $file: " .
                   "size: ${ow}x${oh} -> ${maxw}x${maxh}; " .
                   "aspect: $oaspect -> $naspect; " .
                   "margin: $miny $minx $y2 $x2\n";
    } else {
      print STDERR "$progname: $file: unchanged: $oaspect\n";
    }
  }

  system ("open", "-a", "MPEG Streamclip", $file) if ($edit_p);
}


sub error($) {
  my ($err) = @_;
  print STDERR "$progname: $err\n";
  exit 1;
}

sub usage() {
  print STDERR "usage: $progname [--verbose] [--edit] files ...\n";
  exit 1;
}

sub main() {
  my @files = ();
  my $edit_p = 0;
  while ($#ARGV >= 0) {
    $_ = shift @ARGV;
    if (m/^--?verbose$/) { $verbose++; }
    elsif (m/^-v+$/) { $verbose += length($_)-1; }
    elsif (m/^--?edit$/) { $edit_p++; }
    elsif (m/^-./) { usage; }
    else { push @files, $_; }
  }

  usage unless ($#files >= 0);
  foreach my $f (@files) {
    bbox ($f, $edit_p);
  }
}

main();
exit 0;
