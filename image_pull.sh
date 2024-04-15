#!/bin/bash

########################################################################
# Author: Jason Schmidt
# Created on: 15-Apr-2024
# Version: 0.1
# License: MIT
#
# Description:
# This script automates the process of pulling Docker images, re-tagging
# them under a new registry and namespace, and pushing them to the specified
# repository. It checks for the availability of required tools, handles
# multiple images, and ensures that the original tag of each image is retained.
#
# This script will also pull down the collateral on the image stored by the
# Iron Bank repository. This is downloaded into a user-defined directory as
# well as the current output from Docker Scout.
#
# Usage:
# ./image_pull.sh
#
# DISCLAIMER:
# This script is provided "as is", without warranty of any kind, express or
# implied, including but not limited to the warranties of merchantability,
# fitness for a particular purpose and noninfringement. In no event shall the
# authors or copyright holders be liable for any claim, damages or other
# liability, whether in an action of contract, tort or otherwise, arising from,
# out of or in connection with the software or the use or other dealings in the
# software.
########################################################################

# List of required tools
required_tools=("docker" "cosign" "jq")

# Where we are storing the images
new_registry="demonstrationorg"

# Base directory to store output files
base_output_dir="attestations"

# File containing the list of images
image_list_file="images.txt"

# Function to check for tool availability
check_tool_availability() {
    local tool_name=$1
    if ! command -v "$tool_name" &> /dev/null; then
        echo "$tool_name is not installed. Please install $tool_name and try again."
        exit 1
    fi
}

# Check each tool
for tool in "${required_tools[@]}"; do
    check_tool_availability "$tool"
done

echo "All necessary tools are installed."

# List of predicate types with corresponding URLs
declare -a predicate_types=(
  "https://vat.dso.mil/api/p1/predicate/beta1"
  "https://repo1.dso.mil/dsop/dccscr/-/raw/master/hardening%20manifest/README.md"
  "https://spdx.dev/Document"
  "https://cyclonedx.org/schema"
)

# Check if image list file exists
if [ ! -f "$image_list_file" ]; then
  echo "Image list file not found: $image_list_file"
  exit 1
fi

# Read each image from the file
while IFS= read -r image; do
  echo "----------------------------------------"
  echo "Processing image: $image"

  # Create a specific directory for this image's output
  safe_image_name=$(echo "$image" | tr "/:" "__")
  output_dir="${base_output_dir}/${safe_image_name}"
  mkdir -p "$output_dir"

  for predicate_type in "${predicate_types[@]}"; do
    echo "Processing $predicate_type"

    # Determine filename based on predicate type
    case $predicate_type in
      'https://vat.dso.mil/api/p1/predicate/beta1')
        filename="vat_response.json"
        ;;
      'https://repo1.dso.mil/dsop/dccscr/-/raw/master/hardening%20manifest/README.md')
        filename="hardening_manifest.json"
        ;;
      'https://spdx.dev/Document')
        filename="spdx.json"
        ;;
      'https://cyclonedx.org/schema')
        filename="cyclonedx.json"
        ;;
      *)
        echo "Unknown predicate type: $predicate_type"
        continue
        ;;
    esac

    # Attempt to download and process the attestation
    if cosign download attestation "$image" | \
       jq -r '(.payload | @base64d)' | \
       jq -c 'select(.predicateType == "'$predicate_type'")' > "${output_dir}/${filename}"; then
      echo "File saved: ${output_dir}/${filename}"
    else
      echo "Failed to process or save data for $predicate_type"
    fi
  done

  # Function to re-tag and push an image
  retag_and_push_image() {
      local original_image=$1
      local base_image_name=$(echo "$original_image" | cut -d '/' -f3 | cut -d ':' -f1)
      local tag=$(echo "$original_image" | grep -o ':[^:]*$')
      local new_image="${new_registry}/${base_image_name}${tag}"

      echo "Pulling image $original_image"
      docker pull "$original_image"

      echo "Tagging image $original_image as $new_image"
      docker tag "$original_image" "$new_image"

      echo "Pushing image $new_image"
      docker push "$new_image"

      echo "Running docker scout on $new_image"
      docker scout cves --format markdown "$new_image" > "${output_dir}"/scout.md
  }


  retag_and_push_image "$image"
  echo "Retagged and pushed $image to $new_registry"
  echo "Output for $image saved in $output_dir"
done < "$image_list_file"

echo "All images processed."
