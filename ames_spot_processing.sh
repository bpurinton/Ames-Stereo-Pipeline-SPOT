#!/usr/bin/env bash

# See Purinton, Mueting, and Bookhagen (2022) Remote Sensing for description
# of processing steps in Section 3.2.3. Note that STEP 1 (GeoTiff conversion)
# is done as a separate first step (see GitHub README: https://github.com/UP-RS-ESP/Ames-Stereo-Pipeline-SPOT).

#############################################
###### Here are the parameters to set #######
#############################################

# Name, resolution and alignment parameters
area_name=Pocitos # shortname to give to the output DEM (same as subdirectory name you should be inside of)
rawRes=0.000014532898450 # pixel resolution in degrees
rawRes_meters=1.5 # pixel resolution in meters
multiplier=2 # multiple of raw resolution for output DEMs
resOut=$(echo $multiplier $rawRes | awk '{printf "%4.15f\n",$1*$2}') # output resolution in degrees
resOut_meters=$(echo $multiplier $rawRes_meters | awk '{printf "%4.15f\n",$1*$2}') # approximate output resolution in meters
dem_name=Alignment_DEMs/cop1_s26w68_s25w66_wgs84.tif # DEM for alignment including path

# Stereo Correlation parameters
# for correlation memory limit and tile size discussion, see:
    # https://groups.google.com/g/ames-stereo-pipeline-support/c/nZf71YhJhuE/m/36UNaXPNCAAJ
corr_mem_limit_mb=14336 # correlation memory limit, decrease for less powerful machines
corr_tile_size=6400 # correlation tile size, decrease for less powerful machines
spr=2 # subpixel refinement; typically use Bayes EM (2) but there are some other options

# image pairs to loops through (AB, AC, BC)
is=( A A B )
js=( B C C )

# BM parameters
bmCKernels=( 15 25 35 ) # correlation kernel sizes
bmSKernels=( 25 35 45 ) # subpixel kernel sizes corresponding to CKs above
bmCM=2 # cost mode, for very large ck>9, need to use cost mode 2 (NCC); otherwise best to use 3 (census) or 4 (ternary census)

# MGM parameters
mgmCKernels=( 5 7 9 ) # correlation kernel sizes
mgmSKernels=( 9 15 21 ) # subpixel kernel sizes corresponding to CKs above
mgmCM=4 # cost mode, for very large ck>9, need to use cost mode 2 (NCC); otherwise best to use 3 (census) or 4 (ternary census)


#############################################
############ Begin processing ###############
#############################################


echo ""
echo $area_name
echo ""

i=A # first image
j=B # second image
k=C # third image

echo ""
echo ${i}${j}${k}
echo ""

# make some sub directories
mkdir -p asp_logs/
mkdir -p asp_out/dems/

# bundle adjust on clip
if [ ! -e asp_logs/ba.${i}${j}${k} ]
then
  echo "bundle adjusting"
  bundle_adjust -t rpc \
      merged_tiles/${i}.tif \
      merged_tiles/${j}.tif \
      merged_tiles/${k}.tif \
      -o asp_out/ba_${i}${j}${k}/${i}${j}${k} --tif-compress Deflate --threads 18 \
      --max-iterations 500 --datum WGS_1984 | tee asp_logs/ba.${i}${j}${k}
fi
echo "bundle adjusted"

# create preliminary DEM for alignment using only A-C pair
if [ ! -e asp_out/dems/preliminary-DEM.tif ]
then
    echo "generate asp_out/dems/preliminary-DEM.tif"

    # initial stereo correlation on non map-projected images
    parallel_stereo --stereo-algorithm asp_bm \
      --xcorr-threshold 2 \
      --cost-mode 2 \
      --corr-kernel 25 25 \
      --subpixel-kernel 35 35 \
      --corr-tile-size ${corr_tile_size} \
      --corr-memory-limit-mb ${corr_mem_limit_mb} \
      --subpixel-mode 2 \
      --bundle-adjust-prefix asp_out/ba_${i}${j}${k}/${i}${j}${k} \
      merged_tiles/${i}.tif \
      merged_tiles/${k}.tif \
      asp_out/dems/stereo_preliminary/preliminary | tee asp_logs/preliminary.stereo.log

    # generation of low-quality alignment DEM
    point2dem --t_srs "+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs" \
      --tr $resOut --threads 0 --nodata-value -9999 \
      asp_out/dems/stereo_preliminary/preliminary*-PC.tif \
      -o asp_out/dems/preliminary | tee asp_logs/preliminary.point2dem.log

    # now align preliminary DEM to Copernicus
    pc_align --max-displacement 1000 ${dem_name} \
      asp_out/dems/preliminary-DEM.tif \
      -o asp_out/dems/align/preliminary-DEM_to_COP1 | tee asp_logs/preliminary.pc_align.log

    # now bundle adjust with alignment transform
    bundle_adjust \
      merged_tiles/${i}.tif \
      merged_tiles/${j}.tif \
      merged_tiles/${k}.tif \
      --initial-transform asp_out/dems/align/preliminary-DEM_to_COP1-transform.txt \
      --input-adjustments-prefix asp_out/ba_${i}${j}${k}/${i}${j}${k} \
      --apply-initial-transform-only \
      -o asp_out/dems/ba/preliminary-DEM_to_COP1 --tif-compress Deflate --threads 18 --datum WGS_1984 \
       | tee asp_logs/preliminary.ba.log

    # map project each
    for f in $i $j $k; do
      mapproject --threads 18 --tr $rawRes \
      --bundle-adjust-prefix asp_out/dems/ba/preliminary-DEM_to_COP1 \
      ${dem_name} \
      merged_tiles/${f}.tif \
      merged_tiles/${f}_DD_WGS84_${rawRes_meters}m.tif
    done

    # for some reason you need to change the filenames to get them to work in the next steps
    for f in $i $j $k; do
    cp asp_out/dems/ba/preliminary-DEM_to_COP1-${f}.adjust \
       asp_out/dems/ba/preliminary-DEM_to_COP1-${f}_DD_WGS84_${rawRes_meters}m.adjust
    done
fi

echo "asp_out/dems/preliminary-DEM.tif exists!"

################################
######## BM - All combos #######
################################
# loop through the DEMs
for idx in "${!is[@]}"; do
  i=${is[$idx]}
  j=${js[$idx]}

  for idx in "${!bmCKernels[@]}"; do
    ck=${bmCKernels[$idx]}
    sk=${bmSKernels[$idx]}

    outname=${area_name}_BM_ck${ck}_sk${sk}
    outnameDEM=${outname}-WGS84-${resOut_meters}m

    if [ ! -e asp_out/dems/${i}${j}_${outnameDEM}-DEM-HS.tif ]
    then
      parallel_stereo -t rpc --stereo-algorithm asp_bm \
      --xcorr-threshold 2 \
      --cost-mode ${bmCM} \
      --corr-kernel ${ck} ${ck} \
      --subpixel-kernel ${sk} ${sk} \
      --corr-tile-size ${corr_tile_size} \
      --corr-memory-limit-mb ${corr_mem_limit_mb} \
      --subpixel-mode ${spr} \
      --bundle-adjust-prefix asp_out/dems/ba/preliminary-DEM_to_COP1 \
      merged_tiles/${i}_DD_WGS84_${rawRes_meters}m.tif \
      merged_tiles/${j}_DD_WGS84_${rawRes_meters}m.tif \
      asp_out/dems/stereo_${i}${j}_${outname}/${i}${j}_${outname} \
      ${dem_name} \
      | tee asp_logs/stereo.${i}${j}_${outname}

      point2dem --max-valid-triangulation-error $rawRes_meters --t_srs "+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs" \
       --tr $resOut --errorimage --threads 0 --nodata-value -9999 \
       asp_out/dems/stereo_${i}${j}_${outname}/${i}${j}_${outname}*-PC.tif \
       -o asp_out/dems/${i}${j}_${outnameDEM}

      gdaldem hillshade -s 111120 asp_out/dems/${i}${j}_${outnameDEM}-DEM.tif \
       asp_out/dems/${i}${j}_${outnameDEM}-DEM-HS.tif
    fi
  done

done

################################
######## MGM - All combos ######
################################
# loop through the DEMs
for idx in "${!is[@]}"; do
  i=${is[$idx]}
  j=${js[$idx]}

  for idx in "${!mgmCKernels[@]}"; do
    ck=${mgmCKernels[$idx]}
    sk=${mgmSKernels[$idx]}

    outname=${area_name}_MGM_ck${ck}_sk${sk}
    outnameDEM=${outname}-WGS84-${resOut_meters}m

    if [ ! -e asp_out/dems/${i}${j}_${outnameDEM}-DEM-HS.tif ]
    then
      parallel_stereo -t rpc --stereo-algorithm asp_mgm \
      --xcorr-threshold 2 \
      --cost-mode ${mgmCM} \
      --corr-kernel ${ck} ${ck} \
      --subpixel-kernel ${sk} ${sk} \
      --corr-tile-size ${corr_tile_size} \
      --corr-memory-limit-mb ${corr_mem_limit_mb} \
      --subpixel-mode ${spr} \
      --bundle-adjust-prefix asp_out/dems/ba/preliminary-DEM_to_COP1 \
      merged_tiles/${i}_DD_WGS84_${rawRes_meters}m.tif \
      merged_tiles/${j}_DD_WGS84_${rawRes_meters}m.tif \
      asp_out/dems/stereo_${i}${j}_${outname}/${i}${j}_${outname} \
      ${dem_name} \
       | tee asp_logs/stereo.${i}${j}_${outname}

      point2dem --max-valid-triangulation-error $rawRes_meters --t_srs "+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs" \
        --tr $resOut --errorimage --threads 0 --nodata-value -9999 \
        asp_out/dems/stereo_${i}${j}_${outname}/${i}${j}_${outname}*-PC.tif \
        -o asp_out/dems/${i}${j}_${outnameDEM}

      gdaldem hillshade -s 111120 asp_out/dems/${i}${j}_${outnameDEM}-DEM.tif \
        asp_out/dems/${i}${j}_${outnameDEM}-DEM-HS.tif
    fi
  done

done

echo "DONE!"
