package main

import (
	"flag"
	"fmt"
	"log"
	"os"

	"sbi-deployment/internal/config"
	"sbi-deployment/internal/deploy"
)

const version = "1.0.0"

func main() {
	var (
		imageTag     = flag.String("tag", "latest", "Image tag to deploy")
		imageName    = flag.String("image", "", "Image name to deploy (default: derived from release name)")
		configFile   = flag.String("config", "./deployment.conf", "Configuration file path")
		showVersion  = flag.Bool("version", false, "Show version")
		setupEnv     = flag.Bool("setup", false, "Run environment setup")
		verbose      = flag.Bool("verbose", false, "Enable verbose logging")
	)
	flag.Parse()

	if *showVersion {
		fmt.Printf("SBI Deployment CLI v%s\n", version)
		return
	}

	if *verbose {
		log.SetOutput(os.Stdout)
	}

	// Load configuration
	cfg, err := config.LoadConfig(*configFile)
	if err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	deployer := deploy.New(cfg, *verbose)

	if *setupEnv {
		log.Println("Setting up environment...")
		if err := deployer.SetupEnvironment(); err != nil {
			log.Fatalf("Environment setup failed: %v", err)
		}
		log.Println("Environment setup completed successfully")
		return
	}

	// Get credentials from environment or prompt
	credentials, err := deployer.GetCredentials()
	if err != nil {
		log.Fatalf("Failed to get credentials: %v", err)
	}

	// Run deployment
	log.Printf("Starting deployment for image tag: %s", *imageTag)
	if err := deployer.Deploy(*imageTag, *imageName, credentials); err != nil {
		log.Fatalf("Deployment failed: %v", err)
	}

	log.Println("Deployment completed successfully")
}