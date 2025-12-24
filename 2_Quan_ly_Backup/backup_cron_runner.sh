#!/bin/bash
set -e

_source_module "$INSTALL_DIR/2_Quan_ly_Backup/"

source "$INSTALL_DIR/create_manual_backup.sh"

create_manual_backup