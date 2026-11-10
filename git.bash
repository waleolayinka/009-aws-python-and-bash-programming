#!/bin/bash


        # git bash script to add, commit, push to branch bash and merge to main branch
        # usage: ./git.sh [commit message]


# From https://patorjk.com/software/taag - big "slant" banner if figlet or pyfiglet is installed
figlet_or_echo() {
  if command -v figlet &>/dev/null; then figlet -f slant "$1"
  elif command python -c "import pyfiglet" &>/dev/null; then command python -m pyfiglet -f slant "$1"
  else echo "=== $1 ==="; fi
}
figlet_or_echo "Branch: bash"


# Check if git is installed
if ! [ -x "$(command -v git)" ]; then
  echo 'Error: git is not installed.' >&2
  exit 1
fi

# Switch to the bash branch (create tracking branch if it doesn't exist locally)
git fetch origin
git stash
if ! git checkout bash 2>/dev/null; then
    echo "Error: Failed to switch to the bash branch." >&2
    exit 1
fi
git stash pop
# Add all changes
git add .
# Commit changes with a message
git commit -m "Update bash branch"
# Push changes to the remote repository
git push origin bash
# Merge bash branch into main branch
git fetch origin
git checkout main 2>/dev/null || git checkout -b main --track origin/main
git merge bash && git push origin main

# Done banner only when the script's last command succeeded; keep its exit status
_rc=$?
[[ $_rc -eq 0 ]] && figlet_or_echo "Done"
exit $_rc