package helm

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// Client represents a Helm client
type Client struct {
	verbose bool
}

// New creates a new Helm client
func New(verbose bool) *Client {
	return &Client{verbose: verbose}
}

// CheckHelm verifies that Helm is available
func (c *Client) CheckHelm() error {
	cmd := exec.Command("helm", "version")
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("helm is not available: %w", err)
	}
	return nil
}

// CheckKubectl verifies that kubectl is available
func (c *Client) CheckKubectl() error {
	cmd := exec.Command("kubectl", "version", "--client")
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("kubectl is not available: %w", err)
	}
	return nil
}

// CheckChartPath verifies that the Helm chart path exists
func (c *Client) CheckChartPath(chartPath string) error {
	if _, err := os.Stat(chartPath); os.IsNotExist(err) {
		return fmt.Errorf("helm chart path does not exist: %s", chartPath)
	}
	return nil
}

// Deploy deploys an application using Helm
func (c *Client) Deploy(chartPath, releaseName, namespace, imageTag string, timeout int) error {
	if c.verbose {
		fmt.Printf("Deploying with Helm: chart=%s, release=%s, namespace=%s, tag=%s\n", 
			chartPath, releaseName, namespace, imageTag)
	}

	args := []string{
		"upgrade", "--install",
		releaseName,
		chartPath,
		"--namespace", namespace,
		"--set", fmt.Sprintf("image.tag=%s", imageTag),
		"--wait",
		"--timeout", fmt.Sprintf("%ds", timeout),
		"--atomic",
	}

	cmd := exec.Command("helm", args...)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("helm deployment failed: %w", err)
	}

	if c.verbose {
		fmt.Printf("Successfully deployed %s\n", releaseName)
	}
	return nil
}

// Rollback performs a Helm rollback
func (c *Client) Rollback(releaseName string) error {
	if c.verbose {
		fmt.Printf("Rolling back release: %s\n", releaseName)
	}

	cmd := exec.Command("helm", "rollback", releaseName)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("helm rollback failed: %w", err)
	}

	if c.verbose {
		fmt.Printf("Successfully rolled back %s\n", releaseName)
	}
	return nil
}

// CheckRolloutStatus verifies the deployment status in Kubernetes
func (c *Client) CheckRolloutStatus(releaseName, namespace string) error {
	if c.verbose {
		fmt.Printf("Checking rollout status for %s in namespace %s\n", releaseName, namespace)
	}

	cmd := exec.Command("kubectl", "rollout", "status", 
		fmt.Sprintf("deployment/%s", releaseName), 
		"-n", namespace)
	
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("rollout status check failed: %w", err)
	}

	if !strings.Contains(string(output), "successfully rolled out") {
		return fmt.Errorf("deployment did not roll out successfully")
	}

	if c.verbose {
		fmt.Printf("Rollout status check passed for %s\n", releaseName)
	}
	return nil
}