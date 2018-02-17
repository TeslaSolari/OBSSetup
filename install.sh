#!/bin/bash
# Scriptacular - install.sh
# Copyright 2013 Christopher Simpkins
# MIT License

TARGET_DIR="path/to/the/install/directory"
INSTALL_FILE="your-file.txt"
SUCCESS_MSG="Sexy message for user goes here!"

if [ -d "$TARGET_DIR" ]; then
  cp "$INSTALL_FILE" "$TARGET_DIR"
  echo "$SUCCESS_MSG"
else
  echo "Creating the install directory path..."
  mkdir -p "$TARGET_DIR"
  echo "Done. Installing '$INSTALL_FILE'..."
  cp "$INSTALL_FILE" "$TARGET_DIR"
  echo "$SUCCESS_MSG"
fi

#Setup User
sudo su -c "useradd mynewuser -s /bin/bash -m -g $PRIMARYGRP -G $MYGROUP"

#Add sauces
#Handbreak
sudo add-apt-repository ppa:stebbins/handbrake-releases
#mkvtoolnix
wget -q -O - https://mkvtoolnix.download/gpg-pub-moritzbunkus.txt | sudo apt-key add -
sudo sh -c 'echo "deb http://mkvtoolnix.download/ubuntu/$(lsb_release -sc)/ ./" >> /etc/apt/sources.list.d/bunkus.org.list'

#setup DVD Ripper
sudo apt-get install handbrake-cli
sudo apt-get install handbrake
sudo apt-get install mkvtoolnix mkvtoolnix-gui
sudo apt-get install gddrescue


exit 0


