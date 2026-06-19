package cmd

import (
	"runtime"
	"testing"

	"github.com/samber/lo"
	"github.com/spf13/cobra"
)

// TestEnvCollisions ensures that there are no collisions in the produced environment
// variable names for all commands and their flags.
func TestEnvCollisions(t *testing.T) {
	testEnvCollisions(t, rootCmd)
}

func TestDefaultRootPathUsesHomeDirectory(t *testing.T) {
	home := t.TempDir()
	if runtime.GOOS == "windows" {
		t.Setenv("USERPROFILE", home)
	} else {
		t.Setenv("HOME", home)
	}

	if got := defaultRootPath(); got != home {
		t.Fatalf("defaultRootPath() = %q, want %q", got, home)
	}
}

func testEnvCollisions(t *testing.T, cmd *cobra.Command) {
	for _, cmd := range cmd.Commands() {
		testEnvCollisions(t, cmd)
	}

	replacements := generateEnvKeyReplacements(cmd)
	envVariables := []string{}

	for i := range replacements {
		if i%2 != 0 {
			envVariables = append(envVariables, replacements[i])
		}
	}

	duplicates := lo.FindDuplicates(envVariables)

	if len(duplicates) > 0 {
		t.Errorf("Found duplicate environment variable keys for command %q: %v", cmd.Name(), duplicates)
	}
}
