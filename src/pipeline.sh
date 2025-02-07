#!/bin/bash

# Redirect all output to output.log
exec > >(tee /OUTPUTS/output.log) 2>&1

# Default parameters
total_readout_time=0.05
TOPUP=true
motion_corrected=false
skull_stripped=false
custom_cnf=false
no_smoothing=false
skip_bias_correction=false

# Default filenames
T1_FILE="T1.nii.gz"
BOLD_FILE="BOLD_d.nii.gz"

function usage() {
    cat << EOM
Usage: $0 [options]

Options:
  -nt, --no_topup               Disable TOPUP distortion correction.
  -mc, --motion_corrected       Indicate that the BOLD file is already motion-corrected.
  -ss, --skull_stripped         Indicate that the T1 file is already skull-stripped.
      --custom_cnf              Indicate that a custom .cnf file is present (exactly 1 .cnf).
      --no_smoothing            Disable smoothing.
      --total_readout_time      Specify a custom total readout time (default: 0.05).
      --T1 <FILE>               Specify a custom T1 file name (default: T1.nii.gz).
      --BOLD <FILE>             Specify a custom BOLD file name (default: BOLD_d.nii.gz).
      --no_bias_correction      Skip the N4BiasFieldCorrection (bias correction).
  -h, --help                    Show this help information and exit.

EOM
    exit 0
}

echo "Flag(s) received:"
if [ $# -eq 0 ]; then
    usage
fi

# Check if user asked for help
for ((i=1; i<=$#; i++)); do
    arg="${!i}"
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
        usage
    fi
done

# Process command-line arguments
for ((i=1; i<=$#; i++)); do
    arg="${!i}"
    echo "  $arg"
    
    case $arg in
        -nt|--no_topup)
            TOPUP=false
            ;;
        -mc|--motion_corrected)
            motion_corrected=true
            ;;
        -ss|--skull_stripped)
            skull_stripped=true
            ;;
        --custom_cnf)
            custom_cnf=true
            ;;
        --no_smoothing)
            no_smoothing=true
            ;;
        --no_bias_correction)
            skip_bias_correction=true
            ;;
        --total_readout_time)
            ((i++))
            if [ $i -le $# ]; then
                total_readout_time=${!i}
            else
                echo "Error: Missing value for --total_readout_time"
                exit 1
            fi
            ;;
        --T1)
            ((i++))
            if [ $i -le $# ]; then
                T1_FILE="${!i}"
            else
                echo "Error: Missing value for --T1"
                exit 1
            fi
            ;;
        --BOLD)
            ((i++))
            if [ $i -le $# ]; then
                BOLD_FILE="${!i}"
            else
                echo "Error: Missing value for --BOLD"
                exit 1
            fi
            ;;
    esac
done

echo "Flags for this run:"
echo "  TOPUP: $TOPUP"
echo "  Motion Corrected: $motion_corrected"
echo "  Skull Stripped: $skull_stripped"
echo "  Custom Cnf: $custom_cnf"
echo "  No Smoothing: $no_smoothing"
echo "  Skip Bias Correction: $skip_bias_correction"
echo "  Total Readout Time: $total_readout_time"
echo "  T1 file: $T1_FILE"
echo "  BOLD file: $BOLD_FILE"

# We are no longer using FreeSurfer's environment:
# source $FREESURFER_HOME/SetUpFreeSurfer.sh
source activate /opt/miniconda3  # for ANTs, FSL, etc.
. ${FSLDIR}/etc/fslconf/fsl.sh
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS = `nproc`

INPUTS_PATH=/INPUTS
RESULTS_PATH=/OUTPUTS

cd "$INPUTS_PATH"

# Check existence of input files
if [ ! -f "$T1_FILE" ]; then
    echo "Error: T1 file '$T1_FILE' not found in /INPUTS"
    exit 1
fi
if [ ! -f "$BOLD_FILE" ]; then
    echo "Error: BOLD file '$BOLD_FILE' not found in /INPUTS"
    exit 1
fi

# If using a custom .cnf file, check that exactly one exists
if $custom_cnf; then
    count=$(ls /INPUTS/*.cnf 2>/dev/null | wc -l)
    if [ $count -ne 1 ]; then
        echo "Error: Expected 1 .cnf file, found $count."
        exit 1
    fi
fi

# Copy BOLD to RESULTS
cp "$BOLD_FILE" "$RESULTS_PATH/BOLD_d.nii.gz"
BOLD_PATH="$RESULTS_PATH/BOLD_d.nii.gz"

# Determine the JSON sidecar for the BOLD
BOLD_JSON="${BOLD_FILE%.nii.gz}.json"
if [ ! -f "$BOLD_JSON" ]; then
    echo "Error: JSON sidecar '$BOLD_JSON' not found in /INPUTS"
    exit 1
fi

phase=$(jq -r '.PhaseEncodingDirection' "$BOLD_JSON")
if [ -z "$phase" ] || [ "$phase" = "null" ]; then
    echo "Error: PhaseEncodingDirection not found in $BOLD_JSON"
    exit 1
fi
echo "Extracted PhaseEncodingDirection: $phase"

# Map BIDS PhaseEncodingDirection to acqparams vector
case $phase in
    i)   vector="1 0 0" ;;
    i-)  vector="-1 0 0" ;;
    j)   vector="0 1 0" ;;
    j-)  vector="0 -1 0" ;;
    k)   vector="0 0 1" ;;
    k-)  vector="0 0 -1" ;;
    *)
       echo "Error: Unrecognized PhaseEncodingDirection '$phase'"
       exit 1
       ;;
esac
echo "Computed acqparams vector: $vector"

# Handle dimension of BOLD
BOLD_d_mc="$RESULTS_PATH/BOLD_d_mc.nii.gz"
BOLD_d_3D="$RESULTS_PATH/BOLD_d_3D.nii.gz"

if [[ $(fslorient -getsformcode "$BOLD_PATH") -eq 1 ]] && [[ $(fslorient -getqformcode "$BOLD_PATH") -eq 1 ]]; then
    fslorient -setqformcode 0 "$BOLD_PATH"
fi

dimension=$(mrinfo "$BOLD_PATH" -ndim)
if [[ $dimension -eq 3 ]]; then
    cp "$BOLD_PATH" "$BOLD_d_mc"
    cp "$BOLD_d_mc" "$BOLD_d_3D"
elif [[ $dimension -eq 4 ]]; then
    if $motion_corrected; then
        cp "$BOLD_PATH" "$BOLD_d_mc"
        mrmath "$BOLD_d_mc" mean "$BOLD_d_3D" -axis 3 -force
    else
        mcflirt -in "$BOLD_PATH" -meanvol -out "$RESULTS_PATH/rBOLD" -plots
        mv "$RESULTS_PATH/rBOLD.nii.gz" "$BOLD_d_mc"
        mv "$RESULTS_PATH/rBOLD_mean_reg.nii.gz" "$BOLD_d_3D"
    fi
else
    echo "Error: BOLD_d.nii.gz has an unexpected dimension (not 3D or 4D)."
    exit 1
fi

# -----------------------------------------------------------------------------
# T1: Bias Correction (optional) + Intensity Normalization
# -----------------------------------------------------------------------------
echo "-------"
echo "Processing T1"
T1_PATH="$INPUTS_PATH/$T1_FILE"
T1_N3="$RESULTS_PATH/T1_N3.nii.gz"
T1_NORM="$RESULTS_PATH/T1_norm.nii.gz"

if ! $skip_bias_correction; then
    echo "Performing ANTs N4 bias correction"
    N4BiasFieldCorrection -d 3 -i "$T1_PATH" -o "$T1_N3"
else
    echo "Skipping bias correction; copying T1 as is."
    cp "$T1_PATH" "$T1_N3"
fi

# Now do FAST segmentation + WM-based rescaling
echo "Performing FAST-based WM segmentation"
fast -t 1 -o "${RESULTS_PATH}/fast" "$T1_N3"
# WM partial vol is _pve_2
wm_mask="${RESULTS_PATH}/fast_pve_2.nii.gz"

echo "Creating a (high-purity) WM mask by thresholding"
fslmaths "$wm_mask" -thr 0.99 -bin "${RESULTS_PATH}/fast_wm_mask.nii.gz"

echo "Computing mean WM intensity"
mean_val=$(fslstats "$T1_N3" -k "${RESULTS_PATH}/fast_wm_mask.nii.gz" -M)
desired_mean=110
scale_factor=$(echo "$desired_mean / $mean_val" | bc -l)

echo "Scaling entire T1 by factor $scale_factor"
fslmaths "$T1_N3" -mul "$scale_factor" "$T1_NORM"

# -----------------------------------------------------------------------------
# Skull stripping
# -----------------------------------------------------------------------------
echo "-------"
if $skull_stripped; then
    echo "User indicated T1 is already skull-stripped; creating T1_mask via fslmaths -bin"
    fslmaths "$T1_PATH" -bin "${RESULTS_PATH}/T1_mask.nii.gz"
else
    echo "Skull stripping T1 with BET"
    bet "$T1_N3" "${RESULTS_PATH}/T1_mask.nii.gz" -R
fi

# -----------------------------------------------------------------------------
# EPI registration (BOLD -> T1)
# -----------------------------------------------------------------------------
echo "-------"
echo "epi_reg: Registering distorted BOLD to T1"
epi_reg --epi="$BOLD_d_3D" \
        --t1="$T1_N3" \
        --t1brain="${RESULTS_PATH}/T1_mask.nii.gz" \
        --wmseg="${RESULTS_PATH}/fast_wm_mask.nii.gz" \
        --out="${RESULTS_PATH}/epi_reg_d"

# Convert FSL transform to ANTs format
echo "-------"
echo "Converting FSL transform to ANTs transform"
c3d_affine_tool -ref "$T1_N3" -src "$BOLD_d_3D" \
    "${RESULTS_PATH}/epi_reg_d.mat" -fsl2ras \
    -oitk "${RESULTS_PATH}/epi_reg_d_ANTS.txt"

# -----------------------------------------------------------------------------
# ANTs registration of T1 to atlas
# -----------------------------------------------------------------------------
echo "-------"
# Decide which MNI references to use
if $skull_stripped; then
    T1_ATLAS_PATH=/home/mni_icbm152_t1_tal_nlin_asym_09c_mask.nii.gz
    T1_ATLAS_2_5_PATH=/home/mni_icbm152_t1_tal_nlin_asym_09c_mask_2_5.nii.gz
else
    T1_ATLAS_PATH=/home/mni_icbm152_t1_tal_nlin_asym_09c.nii.gz
    T1_ATLAS_2_5_PATH=/home/mni_icbm152_t1_tal_nlin_asym_09c_2_5.nii.gz
fi

echo "Running ANTs affine registration (T1 -> MNI atlas)"
antsRegistration \
  --verbose 1 \
  --dimensionality 3 \
  --float 0 \
  --collapse-output-transforms 1 \
  --output [ \
    ${RESULTS_PATH}/ANTS, \
    ${RESULTS_PATH}/ANTSWarped.nii.gz \
  ] \
  --interpolation Linear \
  --use-histogram-matching 0 \
  --winsorize-image-intensities [0.005,0.995] \
  --initial-moving-transform [ \
    $T1_ATLAS_PATH, \
    $T1_NORM, \
    1 \
  ] \
  \
  --transform Rigid[0.1] \
  --metric MI[ \
    $T1_ATLAS_PATH, \
    $T1_NORM, \
    1, \
    32, \
    Regular, \
    0.25 \
  ] \
  --convergence [1000x500x250x0, 1e-6, 10] \
  --shrink-factors 8x4x2x1 \
  --smoothing-sigmas 3x2x1x0vox \
  \
  --transform Affine[0.1] \
  --metric MI[ \
    $T1_ATLAS_PATH, \
    $T1_NORM, \
    1, \
    32, \
    Regular, \
    0.25 \
  ] \
  --convergence [1000x500x250x0, 1e-6, 10] \
  --shrink-factors 8x4x2x1 \
  --smoothing-sigmas 3x2x1x0vox

# -----------------------------------------------------------------------------
# Apply transforms to T1 and BOLD into atlas space
# -----------------------------------------------------------------------------
echo "-------"
echo "Applying linear transform to T1"
antsApplyTransforms \
    -d 3 \
    -i "$T1_NORM" \
    -r "$T1_ATLAS_2_5_PATH" \
    -n BSpline \
    -t "${RESULTS_PATH}/ANTS0GenericAffine.mat" \
    -o "${RESULTS_PATH}/T1_norm_lin_atlas_2_5.nii.gz"

echo "-------"
echo "Applying linear transform to distorted BOLD"
antsApplyTransforms \
    -d 3 \
    -i "$BOLD_d_3D" \
    -r "$T1_ATLAS_2_5_PATH" \
    -n BSpline \
    -t "${RESULTS_PATH}/ANTS0GenericAffine.mat" \
    -t "${RESULTS_PATH}/epi_reg_d_ANTS.txt" \
    -o "${RESULTS_PATH}/BOLD_d_3D_lin_atlas_2_5.nii.gz"

cd "$RESULTS_PATH"

# -----------------------------------------------------------------------------
# Run inference for each fold
# -----------------------------------------------------------------------------
NUM_FOLDS=5
for i in $(seq 1 $NUM_FOLDS); do 
    echo "Performing inference on FOLD: $i"
    python3 /home/inference.py \
        T1_norm_lin_atlas_2_5.nii.gz \
        BOLD_d_3D_lin_atlas_2_5.nii.gz \
        BOLD_s_3D_lin_atlas_2_5_FOLD_$i.nii.gz \
        /home/Models/num_fold_${i}_total_folds_5_seed_1_num_epochs_120_lr_0.0001_betas_\(0.9,\ 0.999\)_weight_decay_1e-05_num_epoch_*.pth
done

echo "Taking ensemble average of folds"
fslmerge -t BOLD_s_3D_lin_atlas_2_5_merged.nii.gz BOLD_s_3D_lin_atlas_2_5_FOLD_*.nii.gz
fslmaths BOLD_s_3D_lin_atlas_2_5_merged.nii.gz -Tmean BOLD_s_3D_lin_atlas_2_5.nii.gz

echo "Applying inverse transform to undistorted BOLD_s"
antsApplyTransforms \
    -d 3 \
    -i BOLD_s_3D_lin_atlas_2_5.nii.gz \
    -r "$BOLD_d_3D" \
    -n BSpline \
    -t [epi_reg_d_ANTS.txt,1] \
    -t [ANTS0GenericAffine.mat,1] \
    -o BOLD_s_3D.nii.gz

# -----------------------------------------------------------------------------
# Optional smoothing
# -----------------------------------------------------------------------------
if ! $no_smoothing; then
    echo "Slight smoothing of distorted BOLD"
    fslmaths "$BOLD_d_3D" -s 1.15 BOLD_d_3D_smoothed.nii.gz
    fslmerge -t BOLD_all BOLD_d_3D_smoothed.nii.gz BOLD_s_3D.nii.gz
else
    fslmerge -t BOLD_all "$BOLD_d_3D" BOLD_s_3D.nii.gz
fi

# -----------------------------------------------------------------------------
# TOPUP (if enabled)
# -----------------------------------------------------------------------------
if $TOPUP; then
    echo "Creating acqparams.txt using vector: $vector"
    echo -e "${vector} ${total_readout_time}\n${vector} 0" > acqparams.txt

    data_matrix=($(mrinfo "$BOLD_PATH" -size))
    all_even=true
    for i in {0..2}; do
        if (( ${data_matrix[i]} % 2 == 1 )); then
            all_even=false
            echo "Odd dimension detected"
            break
        fi
    done

    if $custom_cnf; then
        cnf=$(ls /INPUTS/*.cnf | head -n 1)
        cp "$cnf" .
    elif $all_even; then
        cnf=b02b0_2.cnf
        cp /opt/fsl/src/fsl-topup/flirtsch/b02b0_2.cnf .
    else
        cnf=b02b0_1.cnf
        cp /opt/fsl/src/fsl-topup/flirtsch/b02b0_1.cnf .
    fi

    topup -v \
        --imain=BOLD_all.nii.gz \
        --datain=acqparams.txt \
        --config=${cnf} \
        --iout=BOLD_all_topup \
        --fout=topup_results_field \
        --out=topup_results \
        --nthr=${ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS}

    applytopup \
        --imain="$BOLD_d_mc" \
        --datain=acqparams.txt \
        --inindex=1 \
        --topup=topup_results \
        --out=BOLD_u \
        --method=jac

    dimension=$(mrinfo BOLD_u.nii.gz -ndim)
    echo "BOLD_u.nii.gz dimension: $dimension"
    if [[ $dimension -eq 4 ]]; then
        mrmath BOLD_u.nii.gz mean BOLD_u_3D.nii.gz -axis 3 -force
    elif [[ $dimension -eq 3 ]]; then
        cp BOLD_u.nii.gz BOLD_u_3D.nii.gz
    else
        echo "Error: BOLD_u.nii.gz has an unexpected dimension"
    fi
fi
