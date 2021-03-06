#! /bin/bash
# ============================================================================
# Developing brain Region Annotation With Expectation-Maximization (Draw-EM)
#
# Copyright 2013-2020 Imperial College London
# Copyright 2013-2020 Andreas Schuh
# Copyright 2013-2020 Antonios Makropoulos
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ============================================================================

usage()
{
  base=$(basename "$0")
  echo "usage: $base subject_T2.nii.gz scan_age [options]
This script runs the neonatal segmentation pipeline of Draw-EM.

Arguments:
  subject_T2.nii.gz             Nifti Image: The T2 image of the subject to be segmented.
  scan_age                      Number: Subject age in weeks. This is used to select the appropriate template for the initial registration. 
              If the age is <28w or >44w, it will be set to 28w or 44w respectively.
Options:
  -a / -atlas  <atlasname>      Atlas used for the segmentation, options: `echo $AVAILABLE_ATLASES|sed -e 's: :, :g'` (default: `echo $AVAILABLE_ATLASES|cut -d ' ' -f1`)
  -ta / -tissue-atlas  <atlasname>  Atlas used to compute the GM tissue probability, options: `echo $AVAILABLE_TISSUE_ATLASES|sed -e 's: :, :g'` (default: `echo $AVAILABLE_TISSUE_ATLASES|cut -d ' ' -f1`)
  -m / -mask <mask>             Brain mask to use for segmentation instead of computing it with BET
  -d / -data-dir  <directory>   The directory used to run the script and output the files.
  -c / -cleanup  <0/1>          Whether cleanup of temporary files is required (default: 1)
  -p / -save-posteriors  <0/1>  Whether the structures' posteriors are required (default: 0)
  -t / -threads  <number>       Number of threads (CPU cores) allowed for the registration to run in parallel (default: 1)
  -v / -verbose  <0/1>          Whether the script progress is reported (default: 1)
  -h / -help / --help           Print usage.
"
  exit;
}



if [ -n "$DRAWEMDIR" ]; then
  [ -d "$DRAWEMDIR" ] || { echo "DRAWEMDIR environment variable invalid!" 1>&2; exit 1; }
else
  export DRAWEMDIR="$(cd "$(dirname "$BASH_SOURCE")"/.. && pwd)"
fi
# initial configuration
. $DRAWEMDIR/parameters/configuration.sh

[ $# -ge 2 ] || { usage; }
T2=$1
age=$2

[ -f "$T2" ] || { echo "The T2 image provided as argument does not exist!" >&2; exit 1; }
subj=`basename $T2  |sed -e 's:.nii.gz::g' |sed -e 's:.nii::g'`
age=`printf "%.*f\n" 0 $age` #round



cleanup=1 # whether to delete temporary files once done
datadir=`pwd`
posteriors=0   # whether to output posterior probability maps
threads=1
verbose=1
command="$@"
atlas=`echo $AVAILABLE_ATLASES|cut -d ' ' -f1`
tissue_atlas=`echo $AVAILABLE_TISSUE_ATLASES|cut -d ' ' -f1`
mask=""

while [ $# -gt 0 ]; do
  case "$3" in
    -c|-cleanup)  shift; cleanup=$3; ;;
    -d|-data-dir)  shift; datadir=$3; ;;
    -p|-save-posteriors) shift; posteriors=$3; ;;
    -a|-atlas)  shift; atlas=$3; ;;
    -ta|-tissue-atlas)  shift; tissue_atlas=$3; ;;
    -m|-mask)  shift; mask=$3; ;;
    -t|-threads)  shift; threads=$3; ;; 
    -v|-verbose)  shift; verbose=$3; ;; 
    -h|-help|--help) usage; ;;
    -*) echo "$0: Unrecognized option $1" >&2; usage; ;;
     *) break ;;
  esac
  shift
done

# atlas configuration
. $DRAWEMDIR/parameters/set_atlas.sh $tissue_atlas $atlas

# copy required files
mkdir -p $datadir/T2 
if [[ "$T2" != *nii.gz ]];then
  mirtk convert-image $T2 $datadir/T2/$subj.nii.gz
else
  cp $T2 $datadir/T2/$subj.nii.gz
fi

if [ "$mask" != "" ];then
  mkdir -p $datadir/segmentations
  if [[ "$mask" != *nii.gz ]];then
    mirtk convert-image $mask $datadir/segmentations/${subj}_brain_mask.nii.gz
  else
    cp $mask $datadir/segmentations/${subj}_brain_mask.nii.gz
  fi
fi

cd $datadir


version=`cat $DRAWEMDIR/VERSION`
gitversion=`git -C "$DRAWEMDIR" rev-parse HEAD`

[ $verbose -le 0 ] || { echo "DrawEM multi atlas  $version (branch version: $gitversion)
Subject:      $subj
Age:          $age
Tissue atlas: $tissue_atlas
Atlas:        $atlas
Directory:    $datadir
Posteriors:   $posteriors
Cleanup:      $cleanup
Threads:      $threads

$BASH_SOURCE $command
----------------------------"; }

mkdir -p logs || exit 1

run_script()
{
  echo "$@"
  "$DRAWEMDIR/scripts/$@"
  if [ ! $? -eq 0 ]; then
    echo "$DRAWEMDIR/scripts/$@ : failed"
    exit 1
  fi
}

rm -f logs/$subj logs/$subj-err
run_script preprocess.sh        $subj
# registration of atlases
run_script register-multi-atlas.sh $subj $age $threads
# structural segmentation
run_script labels-multi-atlas.sh   $subj
run_script segmentation.sh      $subj
# post-processing
run_script separate-hemispheres.sh  $subj
run_script correct-segmentation.sh  $subj
run_script postprocess.sh       $subj

# if probability maps are required
[ "$posteriors" == "0" -o "$posteriors" == "no" -o "$posteriors" == "false" ] || run_script postprocess-pmaps.sh $subj

# cleanup
if [ "$cleanup" == "1" -o "$cleanup" == "yes" -o "$cleanup" == "true" ] && [ -f "segmentations/${subj}_labels.nii.gz" ];then
  run_script clear-data.sh $subj
fi

exit 0
