#!/usr/bin/env python

""" Git python script to add, commit, push to branch python and merge to main branch """

""" This script automates the process of adding, committing, pushing changes to a specified branch, and merging those changes into the main branch. """
""" usage: python git.py <commit_message> """


# From https://patorjk.com/software/taag - big "slant" banner if figlet or pyfiglet is installed
import sys
import subprocess


def print_banner():
    try:
        import pyfiglet
        banner = pyfiglet.figlet_format("Branch-Python", font="slant")
        print(banner)
    except ImportError:
        print("Branch-Python")

# Check if git is installed


def check_git_installed():
    import subprocess
    try:
        subprocess.run(["git", "--version"], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError:
        print("Git is not installed. Please install Git and try again.")
        exit(1)

# List branches and switch to branch python


def switch_to_branch(branch_name):
    import subprocess
    try:
        subprocess.run(["git", "checkout", branch_name], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError:
        print(f"Failed to switch to branch {branch_name}")
        exit(1)
# Print the current branch name


def print_current_branch():
    import subprocess
    try:
        result = subprocess.run(["git", "branch", "--show-current"], check=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        print(f"Current branch: {result.stdout.decode('utf-8').strip()}")
    except subprocess.CalledProcessError:
        print("Failed to get current branch")
        exit(1)


if __name__ == "__main__":
    commit_message = " ".join(sys.argv[1:]) if len(
        sys.argv) > 1 else "Update python branch"
    print_banner()
    check_git_installed()
    switch_to_branch("python")
    print_current_branch()
    print("You are on the python branch.")
    try:
        subprocess.run(["git", "add", "."], check=True)
        subprocess.run(["git", "commit", "-m", commit_message], check=True)
        subprocess.run(["git", "push", "origin", "python"], check=True)
        subprocess.run(["git", "checkout", "main"], check=True)
        subprocess.run(["git", "merge", "python"], check=True)
        print("Changes have been pushed to the python branch and merged into main.")
        print_done_banner()
    except subprocess.CalledProcessError as e:
        print(f"Error: {e}")
        sys.exit(1)

# Done banner only when the script's last command succeeded; keep its exit status


def print_done_banner():
    try:
        import pyfiglet
        banner = pyfiglet.figlet_format("Done", font="slant")
        print(banner)
    except ImportError:
        print("Done")
