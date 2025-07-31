package docker

import (
	"fmt"
	"os/exec"
	"strings"
)

// Client represents a Docker client
type Client struct {
	verbose bool
	dryRun  bool
}

// New creates a new Docker client
func New(verbose, dryRun bool) *Client {
	return &Client{
		verbose: verbose,
		dryRun:  dryRun,
	}
}

// CheckDocker verifies that Docker is available and running
func (c *Client) CheckDocker() error {
	cmd := exec.Command("docker", "version")
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("docker is not available or not running: %w", err)
	}
	return nil
}

// Login authenticates with a Docker registry
func (c *Client) Login(registry, username, password string) error {
	if c.verbose {
		fmt.Printf("Logging in to registry: %s\n", registry)
	}

	cmd := exec.Command("docker", "login", registry, "-u", username, "--password-stdin")
	cmd.Stdin = strings.NewReader(password)
	
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to login to registry %s: %w", registry, err)
	}
	
	if c.verbose {
		fmt.Printf("Successfully logged in to %s\n", registry)
	}
	return nil
}

// Pull downloads an image from a registry
func (c *Client) Pull(image string) error {
	if c.verbose {
		fmt.Printf("Pulling image: %s\n", image)
	}

	cmd := exec.Command("docker", "pull", image)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to pull image %s: %w", image, err)
	}

	if c.verbose {
		fmt.Printf("Successfully pulled %s\n", image)
	}
	return nil
}

// Tag creates a new tag for an existing image
func (c *Client) Tag(sourceImage, targetImage string) error {
	if c.verbose {
		fmt.Printf("Tagging image: %s -> %s\n", sourceImage, targetImage)
	}

	cmd := exec.Command("docker", "tag", sourceImage, targetImage)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to tag image %s as %s: %w", sourceImage, targetImage, err)
	}

	if c.verbose {
		fmt.Printf("Successfully tagged %s as %s\n", sourceImage, targetImage)
	}
	return nil
}

// Push uploads an image to a registry
func (c *Client) Push(image string) error {
	if c.verbose {
		fmt.Printf("Pushing image: %s\n", image)
	}

	cmd := exec.Command("docker", "push", image)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to push image %s: %w", image, err)
	}

	if c.verbose {
		fmt.Printf("Successfully pushed %s\n", image)
	}
	return nil
}

// Remove deletes an image from local storage
func (c *Client) Remove(image string) error {
	if c.verbose {
		fmt.Printf("Removing image: %s\n", image)
	}

	cmd := exec.Command("docker", "rmi", image)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to remove image %s: %w", image, err)
	}

	if c.verbose {
		fmt.Printf("Successfully removed %s\n", image)
	}
	return nil
}