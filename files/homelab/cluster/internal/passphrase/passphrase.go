// Package passphrase generates, normalises and checks cluster join
// passphrases. Generated ones are words from the EFF large wordlist
// (eff_large_wordlist.txt, CC BY 3.0 US, Electronic Frontier Foundation,
// https://www.eff.org/dice), drawn with crypto/rand.
package passphrase

import (
	"bufio"
	"crypto/rand"
	_ "embed"
	"errors"
	"fmt"
	"math"
	"math/big"
	"strings"
)

//go:embed eff_large_wordlist.txt
var wordlistFile string

// DefaultWords is the length of a generated passphrase: 4 x log2(7772),
// about 51.7 bits. The join protocol is a PAKE, so this only has to resist
// online guessing, which the join service rate-limits.
const DefaultWords = 4

// MinLength is the shortest operator-chosen passphrase accepted.
const MinLength = 20

// Words is the generation list: the EFF list minus its four hyphenated
// entries ("drop-down", "t-shirt", ...), which would be ambiguous once
// Normalize joins words with '-'.
var Words = loadWords()

func loadWords() []string {
	var words []string
	sc := bufio.NewScanner(strings.NewReader(wordlistFile))
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) != 2 || strings.Contains(fields[1], "-") {
			continue
		}
		words = append(words, fields[1])
	}
	return words
}

// Generate returns a passphrase of n words and its entropy in bits.
func Generate(n int) (string, float64, error) {
	if n < DefaultWords {
		return "", 0, fmt.Errorf("a passphrase needs at least %d words", DefaultWords)
	}
	max := big.NewInt(int64(len(Words)))
	picked := make([]string, n)
	for i := range picked {
		idx, err := rand.Int(rand.Reader, max)
		if err != nil {
			return "", 0, err
		}
		picked[i] = Words[idx.Int64()]
	}
	return strings.Join(picked, "-"), float64(n) * math.Log2(float64(len(Words))), nil
}

// Normalize is applied on both sides before the passphrase enters the
// PAKE: ASCII only, lower case, and every run of spaces, tabs, '-' or '_'
// becomes one '-', so "Correct Horse battery_staple" and
// "correct-horse-battery-staple" are the same passphrase.
func Normalize(s string) (string, error) {
	var b strings.Builder
	sep := false
	for _, r := range strings.TrimSpace(s) {
		switch {
		case r > 0x7e || r < 0x20 && r != '\t':
			return "", errors.New("passphrase must be printable ASCII")
		case r == ' ' || r == '\t' || r == '-' || r == '_':
			sep = b.Len() > 0
		default:
			if sep {
				b.WriteByte('-')
				sep = false
			}
			if r >= 'A' && r <= 'Z' {
				r += 'a' - 'A'
			}
			b.WriteRune(r)
		}
	}
	if b.Len() == 0 {
		return "", errors.New("passphrase is empty")
	}
	return b.String(), nil
}

// CheckStrength accepts a normalised operator-chosen passphrase of at
// least MinLength characters made of at least DefaultWords distinct words
// of three or more characters. It cannot measure entropy: a well-known
// phrase passes, so generated passphrases are preferred. The message never
// contains the passphrase.
func CheckStrength(normalized string) error {
	distinct := map[string]bool{}
	for _, w := range strings.Split(normalized, "-") {
		if len(w) >= 3 {
			distinct[w] = true
		}
	}
	if len(distinct) >= DefaultWords && len(normalized) >= MinLength {
		return nil
	}
	return fmt.Errorf("passphrase too weak: use at least %d different words of 3+ letters, %d+ characters in all (or leave HOMELAB_JOIN_PASSPHRASE unset to generate one)", DefaultWords, MinLength)
}
