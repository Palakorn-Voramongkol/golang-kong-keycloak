package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/gofiber/fiber/v2"
	jwtware "github.com/gofiber/jwt/v3"
	"github.com/golang-jwt/jwt/v4"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

var (
	mongoClient *mongo.Client
	mongoDB     *mongo.Database
)

// Helper: extract roles from Keycloak JWT "realm_access" claim
func extractRoles(c *fiber.Ctx) ([]string, error) {
	user := c.Locals("user").(*jwt.Token)
	claims := user.Claims.(jwt.MapClaims)

	// Keycloak puts roles under "realm_access":{ "roles":[...] }
	if realmAccess, ok := claims["realm_access"].(map[string]interface{}); ok {
		if roles, ok2 := realmAccess["roles"].([]interface{}); ok2 {
			var out []string
			for _, r := range roles {
				if s, ok3 := r.(string); ok3 {
					out = append(out, s)
				}
			}
			return out, nil
		}
	}
	return nil, fmt.Errorf("no roles in token")
}

// Middleware to allow only users with a specific role
func requireRole(role string) fiber.Handler {
	return func(c *fiber.Ctx) error {
		roles, err := extractRoles(c)
		if err != nil {
			return c.Status(fiber.StatusForbidden).JSON(fiber.Map{
				"error": "Cannot extract roles",
			})
		}
		for _, r := range roles {
			if r == role {
				return c.Next()
			}
		}
		return c.Status(fiber.StatusForbidden).JSON(fiber.Map{
			"error": fmt.Sprintf("Missing role: %s", role),
		})
	}
}

// Connect to MongoDB
func initMongo() {
	mongoURI := os.Getenv("MONGO_URI")
	if mongoURI == "" {
		mongoURI = "mongodb://localhost:27017"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	clientOptions := options.Client().ApplyURI(mongoURI)
	client, err := mongo.Connect(ctx, clientOptions)
	if err != nil {
		log.Fatal("Mongo Connect error:", err)
	}
	if err = client.Ping(ctx, nil); err != nil {
		log.Fatal("Mongo Ping error:", err)
	}
	mongoClient = client
	dbName := os.Getenv("MONGO_DB")
	if dbName == "" {
		dbName = "demo_db"
	}
	mongoDB = client.Database(dbName)
	log.Println("Connected to MongoDB:", mongoURI)
}

func main() {
	// Initialize Mongo
	initMongo()

	app := fiber.New()

	// Public route (no auth)
	app.Get("/public", func(c *fiber.Ctx) error {
		return c.JSON(fiber.Map{
			"message": "This is a public endpoint.",
		})
	})

	// JWT Middleware: validate tokens issued by Keycloak
	keycloakIssuer := os.Getenv("KEYCLOAK_ISSUER")
	if keycloakIssuer == "" {
		keycloakIssuer = "http://localhost:8080/realms/demo-realm"
	}
	// Construct JWKS URL: Keycloak exposes at /protocol/openid-connect/certs
	jwksURL := fmt.Sprintf("%s/protocol/openid-connect/certs", keycloakIssuer)

	app.Use(jwtware.New(jwtware.Config{
		// Parse and validate JWT against JWKS
		KeySetURL: jwksURL,
		// Accept only RS256 tokens
		SigningMethod: "RS256",
		ContextKey:    "user",
		ErrorHandler: func(c *fiber.Ctx, err error) error {
			return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
				"error": "Unauthorized - " + err.Error(),
			})
		},
	}))

	// Protected route: any authenticated user
	app.Get("/profile", func(c *fiber.Ctx) error {
		user := c.Locals("user").(*jwt.Token)
		claims := user.Claims.(jwt.MapClaims)
		username := claims["preferred_username"].(string)
		return c.JSON(fiber.Map{
			"message":  "Hello, " + username,
			"roles":    claims["realm_access"],
			"subject":  claims["sub"],
			"issuedAt": claims["iat"],
		})
	})

	// Protected route: only users with realm role "user"
	app.Get("/user", requireRole("user"), func(c *fiber.Ctx) error {
		return c.JSON(fiber.Map{
			"message": "Hello, user-level endpoint!",
		})
	})

	// Protected route: only users with realm role "admin"
	app.Get("/admin", requireRole("admin"), func(c *fiber.Ctx) error {
		// Example: count documents in a collection
		count, err := mongoDB.Collection("items").CountDocuments(context.Background(), struct{}{})
		if err != nil {
			return c.Status(500).JSON(fiber.Map{
				"error": "Database error",
			})
		}
		return c.JSON(fiber.Map{
			"message":     "Hello, admin-level endpoint!",
			"itemCountDB": count,
		})
	})

	log.Fatal(app.Listen(":3000"))
}
