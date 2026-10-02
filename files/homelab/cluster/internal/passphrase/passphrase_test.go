package passphrase

import (
	"strings"
	"testing"
)

func TestGenerate(t *testing.T) {
	if len(Words) != 7772 {
		t.Fatalf("wordlist: %d words", len(Words))
	}
	p, bits, err := Generate(DefaultWords)
	if err != nil {
		t.Fatal(err)
	}
	if n := len(strings.Split(p, "-")); n != DefaultWords || bits < 51 {
		t.Fatalf("%d words, %.1f bits", n, bits)
	}
	if norm, _ := Normalize(p); norm != p {
		t.Fatal("generated passphrase is not normalised")
	}
	if _, _, err := Generate(3); err == nil {
		t.Fatal("3 words accepted")
	}
}

func TestNormalize(t *testing.T) {
	for in, want := range map[string]string{
		"  Correct Horse\tbattery_staple ": "correct-horse-battery-staple",
		"--a--b__c  ":                      "a-b-c",
	} {
		if got, err := Normalize(in); err != nil || got != want {
			t.Fatalf("Normalize(%q) = %q, %v", in, got, err)
		}
	}
	for _, bad := range []string{"", " - ", "café-horse", "a\x00b"} {
		if _, err := Normalize(bad); err == nil {
			t.Fatalf("Normalize(%q) accepted", bad)
		}
	}
}

func TestCheckStrength(t *testing.T) {
	for _, ok := range []string{"correct-horse-battery-staple", "orbit-maple-candle-riverbank"} {
		if err := CheckStrength(ok); err != nil {
			t.Fatalf("%s: %v", ok, err)
		}
	}
	for _, weak := range []string{"passwordpasswordpassword", "the-cat-sat-mat", "abc-abc-abc-abc-abc-abc", "hunter2"} {
		err := CheckStrength(weak)
		if err == nil {
			t.Fatalf("%s accepted", weak)
		}
		if strings.Contains(err.Error(), weak) {
			t.Fatal("error message contains the passphrase")
		}
	}
}
