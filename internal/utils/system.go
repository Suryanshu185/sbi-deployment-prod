package utils

import (
	"fmt"
	"os"
	"os/exec"
)

// CheckCommand verifies if a command is available in the system
func CheckCommand(command string) error {
	_, err := exec.LookPath(command)
	if err != nil {
		return fmt.Errorf("command %s not found in PATH", command)
	}
	return nil
}

// RunCommand executes a shell command and returns the output
func RunCommand(command string, args ...string) (string, error) {
	cmd := exec.Command(command, args...)
	output, err := cmd.CombinedOutput()
	return string(output), err
}

// FileExists checks if a file exists
func FileExists(filename string) bool {
	_, err := os.Stat(filename)
	return !os.IsNotExist(err)
}

// CreateDir creates a directory if it doesn't exist
func CreateDir(dir string) error {
	if !FileExists(dir) {
		return os.MkdirAll(dir, 0755)
	}
	return nil
}

// InstallPackages installs required system packages
func InstallPackages(packages []string) error {
	fmt.Println("Installing required packages...")
	
	// Update package list
	if err := runCommandWithSudo("apt-get", "update"); err != nil {
		return fmt.Errorf("failed to update package list: %w", err)
	}

	// Install packages
	args := append([]string{"install", "-y"}, packages...)
	if err := runCommandWithSudo("apt-get", args...); err != nil {
		return fmt.Errorf("failed to install packages: %w", err)
	}

	return nil
}

// InstallHelm installs Helm binary
func InstallHelm() error {
	fmt.Println("Installing Helm...")
	
	// Download Helm
	downloadCmd := exec.Command("curl", "-fsSL", "-o", "/tmp/helm.tar.gz", 
		"https://get.helm.sh/helm-v3.12.0-linux-amd64.tar.gz")
	if err := downloadCmd.Run(); err != nil {
		return fmt.Errorf("failed to download Helm: %w", err)
	}

	// Extract and install
	extractCmd := exec.Command("tar", "-zxvf", "/tmp/helm.tar.gz", 
		"-C", "/tmp", "--strip-components=1", "linux-amd64/helm")
	if err := extractCmd.Run(); err != nil {
		return fmt.Errorf("failed to extract Helm: %w", err)
	}

	// Move to /usr/local/bin
	if err := runCommandWithSudo("mv", "/tmp/helm", "/usr/local/bin/helm"); err != nil {
		return fmt.Errorf("failed to install Helm: %w", err)
	}

	// Make executable
	if err := runCommandWithSudo("chmod", "+x", "/usr/local/bin/helm"); err != nil {
		return fmt.Errorf("failed to make Helm executable: %w", err)
	}

	return nil
}

// InstallKubectl installs kubectl binary
func InstallKubectl() error {
	fmt.Println("Installing kubectl...")
	
	// Download kubectl
	downloadCmd := exec.Command("curl", "-LO", 
		"https://dl.k8s.io/release/v1.27.0/bin/linux/amd64/kubectl")
	downloadCmd.Dir = "/tmp"
	if err := downloadCmd.Run(); err != nil {
		return fmt.Errorf("failed to download kubectl: %w", err)
	}

	// Install kubectl
	if err := runCommandWithSudo("install", "-o", "root", "-g", "root", "-m", "0755", 
		"/tmp/kubectl", "/usr/local/bin/kubectl"); err != nil {
		return fmt.Errorf("failed to install kubectl: %w", err)
	}

	return nil
}

// AddUserToDockerGroup adds the current user to the docker group
func AddUserToDockerGroup() error {
	user := os.Getenv("USER")
	if user == "" {
		user = "runner" // Default for CI environments
	}

	fmt.Printf("Adding user %s to docker group...\n", user)
	return runCommandWithSudo("usermod", "-aG", "docker", user)
}

// runCommandWithSudo runs a command with sudo privileges
func runCommandWithSudo(command string, args ...string) error {
	fullArgs := append([]string{command}, args...)
	cmd := exec.Command("sudo", fullArgs...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// IsRoot checks if the current user is root
func IsRoot() bool {
	return os.Geteuid() == 0
}

// GetCurrentUser returns the current username
func GetCurrentUser() string {
	if user := os.Getenv("USER"); user != "" {
		return user
	}
	if user := os.Getenv("USERNAME"); user != "" {
		return user
	}
	return "unknown"
}