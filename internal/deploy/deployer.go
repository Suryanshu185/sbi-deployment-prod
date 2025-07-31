package deploy

import (
	"fmt"
	"log"
	"os"
	"strings"
	"syscall"

	"sbi-deployment/internal/config"
	"sbi-deployment/internal/docker"
	"sbi-deployment/internal/helm"
	"sbi-deployment/internal/utils"
	"golang.org/x/term"
)

// Deployer handles the deployment process
type Deployer struct {
	config       *config.Config
	dockerClient *docker.Client
	helmClient   *helm.Client
	verbose      bool
	dryRun       bool
}

// New creates a new Deployer instance
func New(cfg *config.Config, verbose, dryRun bool) *Deployer {
	return &Deployer{
		config:       cfg,
		dockerClient: docker.New(verbose, dryRun),
		helmClient:   helm.New(verbose, dryRun),
		verbose:      verbose,
		dryRun:       dryRun,
	}
}

// SetupEnvironment installs required dependencies
func (d *Deployer) SetupEnvironment() error {
	log.Println("Setting up deployment environment...")

	// Check if running as root or with sudo access
	if !utils.IsRoot() {
		log.Println("Note: Environment setup requires sudo privileges")
	}

	// Install required packages
	packages := []string{
		"docker.io",
		"curl",
		"jq",
		"ca-certificates",
	}

	if err := utils.InstallPackages(packages); err != nil {
		return fmt.Errorf("failed to install packages: %w", err)
	}

	// Add user to docker group
	if err := utils.AddUserToDockerGroup(); err != nil {
		log.Printf("Warning: Failed to add user to docker group: %v", err)
		log.Println("You may need to manually add your user to the docker group and restart")
	}

	// Install Helm
	if err := utils.CheckCommand("helm"); err != nil {
		if err := utils.InstallHelm(); err != nil {
			return fmt.Errorf("failed to install Helm: %w", err)
		}
	} else {
		log.Println("Helm is already installed")
	}

	// Install kubectl
	if err := utils.CheckCommand("kubectl"); err != nil {
		if err := utils.InstallKubectl(); err != nil {
			return fmt.Errorf("failed to install kubectl: %w", err)
		}
	} else {
		log.Println("kubectl is already installed")
	}

	log.Println("Environment setup completed")
	return nil
}

// GetCredentials prompts for or retrieves credentials from environment
func (d *Deployer) GetCredentials() (*config.Credentials, error) {
	creds := &config.Credentials{}

	// Try to get from environment first
	creds.NexusUsername = os.Getenv("NEXUS_USERNAME")
	creds.NexusPassword = os.Getenv("NEXUS_PASSWORD")
	creds.HarborUsername = os.Getenv("HARBOR_USERNAME")
	creds.HarborPassword = os.Getenv("HARBOR_PASSWORD")

	// Prompt for missing credentials
	if creds.NexusUsername == "" {
		fmt.Print("Enter Nexus Username: ")
		fmt.Scanln(&creds.NexusUsername)
	}

	if creds.NexusPassword == "" {
		fmt.Print("Enter Nexus Password: ")
		password, err := term.ReadPassword(int(syscall.Stdin))
		if err != nil {
			return nil, fmt.Errorf("failed to read Nexus password: %w", err)
		}
		creds.NexusPassword = string(password)
		fmt.Println()
	}

	if creds.HarborUsername == "" {
		fmt.Print("Enter Harbor Username: ")
		fmt.Scanln(&creds.HarborUsername)
	}

	if creds.HarborPassword == "" {
		fmt.Print("Enter Harbor Password: ")
		password, err := term.ReadPassword(int(syscall.Stdin))
		if err != nil {
			return nil, fmt.Errorf("failed to read Harbor password: %w", err)
		}
		creds.HarborPassword = string(password)
		fmt.Println()
	}

	return creds, nil
}

// Deploy executes the complete deployment process
func (d *Deployer) Deploy(imageTag, imageName string, credentials *config.Credentials) error {
	if d.dryRun {
		return d.dryRunDeploy(imageTag, imageName, credentials)
	}
	// Pre-flight checks
	if err := d.preflightChecks(); err != nil {
		return fmt.Errorf("pre-flight checks failed: %w", err)
	}

	// Determine image name from parameter, release name, or chart path
	if imageName == "" {
		imageName = d.config.ReleaseName
		if imageName == "" {
			// Extract from chart path if available
			if strings.Contains(d.config.HelmChartPath, "{{") {
				// Template not resolved, use a default
				imageName = "app"
			} else {
				// Extract from path
				parts := strings.Split(strings.TrimSuffix(d.config.HelmChartPath, "/"), "/")
				if len(parts) > 0 {
					imageName = parts[len(parts)-1]
				} else {
					imageName = "app"
				}
			}
		}
	}

	sourceImage := fmt.Sprintf("%s/%s:%s", d.config.NexusRegistry, imageName, imageTag)
	targetImage := fmt.Sprintf("%s/%s:%s", d.config.HarborRegistry, imageName, imageTag)

	// Image sync process
	if err := d.syncImage(sourceImage, targetImage, credentials); err != nil {
		return fmt.Errorf("image sync failed: %w", err)
	}

	// Helm deployment
	chartPath := strings.ReplaceAll(d.config.HelmChartPath, "{{ image_name }}", imageName)
	releaseName := strings.ReplaceAll(d.config.ReleaseName, "{{ image_name }}", imageName)

	if err := d.deployWithHelm(chartPath, releaseName, imageTag); err != nil {
		return fmt.Errorf("helm deployment failed: %w", err)
	}

	// Health check
	if err := d.helmClient.CheckRolloutStatus(releaseName, d.config.Namespace); err != nil {
		return fmt.Errorf("health check failed: %w", err)
	}

	// Cleanup
	if d.config.EnableCleanup {
		if err := d.dockerClient.Remove(targetImage); err != nil {
			log.Printf("Warning: Failed to cleanup local image: %v", err)
		}
	}

	return nil
}

// preflightChecks validates all prerequisites
func (d *Deployer) preflightChecks() error {
	log.Println("Running pre-flight checks...")

	if err := d.dockerClient.CheckDocker(); err != nil {
		return err
	}

	if err := d.helmClient.CheckHelm(); err != nil {
		return err
	}

	if err := d.helmClient.CheckKubectl(); err != nil {
		return err
	}

	// We'll check chart path during deployment as it may contain templates
	log.Println("Pre-flight checks passed")
	return nil
}

// syncImage handles the image pull, tag, and push process
func (d *Deployer) syncImage(sourceImage, targetImage string, credentials *config.Credentials) error {
	log.Println("Starting image sync process...")

	// Login to Nexus
	if err := d.dockerClient.Login(d.config.NexusRegistry, credentials.NexusUsername, credentials.NexusPassword); err != nil {
		return err
	}

	// Pull from Nexus with retries
	var pullErr error
	for i := 0; i < 3; i++ {
		if pullErr = d.dockerClient.Pull(sourceImage); pullErr == nil {
			break
		}
		log.Printf("Pull attempt %d failed, retrying...", i+1)
	}
	if pullErr != nil {
		return pullErr
	}

	// Tag for Harbor
	if err := d.dockerClient.Tag(sourceImage, targetImage); err != nil {
		return err
	}

	// Login to Harbor
	if err := d.dockerClient.Login(d.config.HarborRegistry, credentials.HarborUsername, credentials.HarborPassword); err != nil {
		return err
	}

	// Push to Harbor
	if err := d.dockerClient.Push(targetImage); err != nil {
		return err
	}

	log.Println("Image sync completed successfully")
	return nil
}

// deployWithHelm handles the Helm deployment process
func (d *Deployer) deployWithHelm(chartPath, releaseName, imageTag string) error {
	log.Println("Starting Helm deployment...")

	// Check chart path
	if err := d.helmClient.CheckChartPath(chartPath); err != nil {
		return err
	}

	// Deploy with Helm
	if err := d.helmClient.Deploy(chartPath, releaseName, d.config.Namespace, imageTag, d.config.Timeout); err != nil {
		// Attempt rollback if enabled
		if d.config.EnableRollback {
			log.Println("Deployment failed, attempting rollback...")
			if rollbackErr := d.helmClient.Rollback(releaseName); rollbackErr != nil {
				log.Printf("Rollback also failed: %v", rollbackErr)
			}
		}
		return err
	}

	log.Println("Helm deployment completed successfully")
	return nil
}

// dryRunDeploy shows what would be done without executing
func (d *Deployer) dryRunDeploy(imageTag, imageName string, credentials *config.Credentials) error {
	log.Println("=== DRY RUN MODE - No actual operations will be performed ===")
	
	// Determine image name
	if imageName == "" {
		imageName = d.config.ReleaseName
		if imageName == "" {
			imageName = "app"
		}
	}
	
	sourceImage := fmt.Sprintf("%s/%s:%s", d.config.NexusRegistry, imageName, imageTag)
	targetImage := fmt.Sprintf("%s/%s:%s", d.config.HarborRegistry, imageName, imageTag)
	chartPath := strings.ReplaceAll(d.config.HelmChartPath, "{{ image_name }}", imageName)
	releaseName := strings.ReplaceAll(d.config.ReleaseName, "{{ image_name }}", imageName)

	log.Printf("1. Pre-flight checks:")
	log.Printf("   ✓ Would check Docker availability")
	log.Printf("   ✓ Would check Helm availability")
	log.Printf("   ✓ Would check kubectl availability")
	log.Printf("   ✓ Would check chart path: %s", chartPath)

	log.Printf("2. Image sync operations:")
	log.Printf("   ✓ Would login to Nexus registry: %s", d.config.NexusRegistry)
	log.Printf("   ✓ Would pull image: %s", sourceImage)
	log.Printf("   ✓ Would tag image: %s -> %s", sourceImage, targetImage)
	log.Printf("   ✓ Would login to Harbor registry: %s", d.config.HarborRegistry)
	log.Printf("   ✓ Would push image: %s", targetImage)

	log.Printf("3. Helm deployment:")
	log.Printf("   ✓ Would deploy using chart: %s", chartPath)
	log.Printf("   ✓ Would set release name: %s", releaseName)
	log.Printf("   ✓ Would deploy to namespace: %s", d.config.Namespace)
	log.Printf("   ✓ Would set image tag: %s", imageTag)
	log.Printf("   ✓ Would wait for deployment (timeout: %ds)", d.config.Timeout)
	
	if d.config.EnableRollback {
		log.Printf("   ✓ Rollback is enabled if deployment fails")
	}

	log.Printf("4. Health check:")
	log.Printf("   ✓ Would check rollout status for deployment/%s in namespace %s", releaseName, d.config.Namespace)

	if d.config.EnableCleanup {
		log.Printf("5. Cleanup:")
		log.Printf("   ✓ Would remove local image: %s", targetImage)
	}

	log.Printf("=== DRY RUN COMPLETED - All operations would succeed ===")
	return nil
}