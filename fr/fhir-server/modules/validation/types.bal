// Copyright (c) 2025, WSO2 LLC. (http://www.wso2.com).
// Licensed under the Apache License, Version 2.0.

# Holds the result of a validation check.
public type ValidationResult record {|
    # True if the resource is valid
    boolean valid;
    # List of validation error messages (empty when valid)
    string[] errors;
|};

# Context passed to validators.
public type ValidationContext record {|
    # FHIR resource type (e.g. "Organization")
    string resourceType;
    # The resource JSON to validate
    json payload;
    # Active tenant/IG identifier (e.g. "mcsd")
    string tenantId = "mcsd";
    # Write operation type: "create" | "update"
    string operation;
|};

// ─────────────────────────────────────────────────────────────────────────────
// Validation Pipeline — Chain of Responsibility Pattern
//
// Rules are chained in order; the pipeline stops on the first failure.
// ─────────────────────────────────────────────────────────────────────────────

# Interface: a single validation rule.
public type ValidationRule object {
    public isolated function validate(ValidationContext ctx) returns ValidationResult;
    public isolated function getName() returns string;
};

# Interface: a chain of validation rules.
public type ValidationPipeline object {
    public function addRule(ValidationRule rule) returns ValidationPipeline;
    public function run(ValidationContext ctx) returns ValidationResult;
};

# DefaultValidationPipeline — iterates rules in order, stops on first failure.
public class DefaultValidationPipeline {
    *ValidationPipeline;
    private ValidationRule[] rules;

    public function init(ValidationRule[] rules = []) {
        self.rules = rules;
    }

    public function addRule(ValidationRule rule) returns ValidationPipeline {
        self.rules.push(rule);
        return self;
    }

    public function run(ValidationContext ctx) returns ValidationResult {
        foreach ValidationRule rule in self.rules {
            ValidationResult result = rule.validate(ctx);
            if !result.valid {
                return result;
            }
        }
        return {valid: true, errors: []};
    }
}

# Builds the default pipeline: FhirBaseValidator → McsdProfileValidator.
public function buildDefaultPipeline() returns ValidationPipeline =>
    new DefaultValidationPipeline([new FhirBaseValidator(), new McsdProfileValidator()]);

# Isolated entry-point for handlers: runs FhirBaseValidator then McsdProfileValidator.
# Stops on the first failure, same semantics as buildDefaultPipeline().run().
public isolated function runDefaultValidation(ValidationContext ctx) returns ValidationResult {
    FhirBaseValidator baseValidator = new ();
    ValidationResult baseResult = baseValidator.validate(ctx);
    if !baseResult.valid {
        return baseResult;
    }
    McsdProfileValidator profileValidator = new ();
    return profileValidator.validate(ctx);
}
