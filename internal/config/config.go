package config

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Config represents the deployment configuration
type Config struct {
	NexusRegistry   string
	HarborRegistry  string
	HelmChartPath   string
	ReleaseName     string
	Namespace       string
	Timeout         int
	EnableRollback  bool
	EnableCleanup   bool
	ImageName       string
}

// Credentials holds registry authentication information
type Credentials struct {
	NexusUsername  string
	NexusPassword  string
	HarborUsername string
	HarborPassword string
}

// LoadConfig reads configuration from the deployment.conf file
func LoadConfig(configFile string) (*Config, error) {
	cfg := &Config{
		Timeout:        300,
		EnableRollback: true,
		EnableCleanup:  true,
	}

	file, err := os.Open(configFile)
	if err != nil {
		return nil, fmt.Errorf("failed to open config file: %w", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])

		switch key {
		case "NEXUS_REGISTRY":
			cfg.NexusRegistry = value
		case "HARBOR_REGISTRY":
			cfg.HarborRegistry = value
		case "HELM_CHART_PATH":
			cfg.HelmChartPath = value
		case "RELEASE_NAME":
			cfg.ReleaseName = value
		case "NAMESPACE":
			cfg.Namespace = value
		case "TIMEOUT":
			if timeout, err := strconv.Atoi(value); err == nil {
				cfg.Timeout = timeout
			}
		case "ENABLE_ROLLBACK":
			cfg.EnableRollback = strings.ToLower(value) == "true"
		case "ENABLE_CLEANUP":
			cfg.EnableCleanup = strings.ToLower(value) == "true"
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	// Validate required fields
	if cfg.NexusRegistry == "" {
		return nil, fmt.Errorf("NEXUS_REGISTRY is required")
	}
	if cfg.HarborRegistry == "" {
		return nil, fmt.Errorf("HARBOR_REGISTRY is required")
	}

	return cfg, nil
}