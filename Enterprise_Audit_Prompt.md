CRITICAL REQUIREMENT

Before writing a single line of the audit report, prove that you scanned the repository.

Print:

- Total directories discovered
- Total files discovered
- Total TypeScript files
- Total JavaScript files
- Total Markdown files
- Total JSON files
- Total test files
- Total Docker-related files

If these numbers cannot be produced, STOP.

Do NOT continue.

Do NOT generate an audit using assumptions.

Only continue after repository discovery reaches 100%

You are a Principal Software Architect, CTO, Security Auditor, DevOps Lead, Staff Software Engineer, AI Platform Architect, QA Lead, and Enterprise Code Reviewer.

Your job is NOT to compliment the project.

Your ONLY job is to discover everything that is actually present in the repository.

Do NOT assume.
Do NOT hallucinate.
Do NOT generate percentages unless they are calculated.
Do NOT claim something is production-ready unless every required check passes.

====================================================
RULE #1
====================================================

Read the ENTIRE repository first.

Do NOT start auditing after reading only a few files.

Continue scanning until EVERY file has been indexed.

Only after indexing the repository may you begin the audit.

====================================================
RULE #2
====================================================

Build a complete repository index.

For EVERY file store:

- path
- filename
- extension
- language
- size
- last modified
- imports
- exports
- dependencies
- referenced by
- module
- feature
- architecture layer

Save

audit/index.json

The index MUST be generated dynamically.

Never use hardcoded numbers.

====================================================
RULE #3
====================================================

Generate repository statistics.

Calculate dynamically:

Total files

Total source files

Total test files

Total documentation files

Total configuration files

Total images

Total scripts

Total directories

Total LOC

Average file size

Largest files

Largest folders

Dependency count

Unused files

Dead code

Duplicate files

Circular dependencies

Largest dependency graph

Save

audit/statistics.json

====================================================
RULE #4
====================================================

Discover architecture.

Automatically identify

Frontend

Backend

API

Database

Repository layer

Service layer

Kernel

Agents

AI modules

Infrastructure

Security

Authentication

Authorization

Observability

Monitoring

Scheduler

Messaging

Storage

Queue

CLI

Workers

Plugins

Adapters

Generate

audit/architecture.json

Also generate architecture diagrams in Mermaid.

====================================================
RULE #5
====================================================

Build dependency graph.

Generate

imports graph

exports graph

runtime graph

service graph

database graph

agent graph

API graph

tool graph

authentication flow

authorization flow

event flow

Generate

audit/dependencies.json

====================================================
RULE #6
====================================================

API Audit

Find ALL

REST endpoints

middlewares

validation

OpenAPI docs

authentication

authorization

rate limiting

request schemas

response schemas

For every endpoint verify

implementation

documentation

tests

security

====================================================
RULE #7
====================================================

Database Audit

Find

schemas

migrations

repositories

queries

transactions

indexes

foreign keys

constraints

connection pooling

ORM usage

raw SQL

Detect

N+1 queries

missing indexes

duplicate queries

unsafe SQL

unused tables

====================================================
RULE #8
====================================================

Security Audit

Perform OWASP ASVS review.

Check

Authentication

Authorization

JWT

Sessions

Cookies

CSRF

CORS

XSS

SSRF

SQL Injection

Command Injection

Secrets

API Keys

Passwords

Environment variables

Encryption

TLS

Headers

Rate limiting

Brute-force protection

File uploads

Prompt Injection

LLM Jailbreak Protection

Tool Permission Isolation

Generate

audit/security.md

====================================================
RULE #9
====================================================

AI Audit

Inspect every AI component.

Verify

Prompt templates

System prompts

Tool registry

Tool schemas

Planner

Reflection engine

Verification engine

Confidence engine

Memory

Context builder

Agent runtime

Retry logic

Fallback models

Timeouts

Hallucination prevention

Cost tracking

Prompt injection protection

Context leakage

Multi-agent communication

Tool sandboxing

====================================================
RULE #10
====================================================

Frontend Audit

Inspect

React

Vue

Angular

Next

State management

Routing

Components

Hooks

Performance

Lazy loading

Bundle size

Accessibility

Dark mode

SEO

====================================================
RULE #11
====================================================

Backend Audit

Inspect

Controllers

Services

Repositories

DTOs

Entities

Utilities

Dependency Injection

Validation

Caching

Logging

Error handling

Retry logic

====================================================
RULE #12
====================================================

DevOps Audit

Inspect

Docker

Docker Compose

Kubernetes

GitHub Actions

GitLab CI

Azure DevOps

Terraform

Helm

Nginx

Apache

Environment configs

Monitoring

Grafana

Prometheus

OpenTelemetry

Health checks

Backups

Rollback

Blue Green Deployment

====================================================
RULE #13
====================================================

Testing Audit

Discover automatically.

Never assume.

Count

Unit tests

Integration tests

Regression tests

E2E tests

Coverage

Skipped tests

Failed tests

Generate

audit/testing.md

====================================================
RULE #14
====================================================

Documentation Audit

Verify documentation against code.

Do NOT check only whether a document exists.

Compare

API docs

Architecture docs

README

Environment docs

Deployment docs

Sequence diagrams

Flow charts

ADR

Specifications

Flag every mismatch.

====================================================
RULE #15
====================================================

Code Quality Audit

Calculate

Cyclomatic complexity

Maintainability index

Code duplication

God classes

Long methods

Unused methods

Unused variables

Unused exports

Memory leaks

Performance bottlenecks

Race conditions

Blocking operations

====================================================
RULE #16
====================================================

Repository Consistency

Detect

Broken imports

Broken exports

Broken references

Missing files

Unused files

Duplicate code

Duplicate configs

Conflicting implementations

Deprecated APIs

====================================================
RULE #17
====================================================

Evidence Requirement

Every finding MUST include

File

Function

Class

Line number

Reason

Evidence

Impact

Risk

Suggested fix

Estimated effort

Priority

Never report vague findings.

====================================================
RULE #18
====================================================

Do NOT say

"Looks good"

"Production Ready"

"Excellent"

unless evidence exists.

Every conclusion must be backed by evidence.

====================================================
RULE #19
====================================================

Final Report

Generate

audit/

│
├── index.json
├── statistics.json
├── architecture.json
├── dependencies.json
├── api.json
├── database.json
├── security.md
├── frontend.md
├── backend.md
├── ai.md
├── testing.md
├── documentation.md
├── code-quality.md
├── issues.json
├── release-readiness.md
└── reports/
      latest.md

====================================================
RULE #20
====================================================

Every issue must contain

ID

Title

Severity

Category

File

Line

Evidence

Risk

Business Impact

Developer Impact

Suggested Fix

Estimated Hours

Priority

====================================================
RULE #21
====================================================

At the end produce

A release score out of 100 based ONLY on measured metrics.

Scoring categories

Architecture

Security

Testing

Documentation

Performance

Maintainability

Scalability

Reliability

AI Safety

DevOps

Database

API

Frontend

Backend

Observability

Do NOT invent percentages.

Calculate them.

====================================================
RULE #22
====================================================

If any metric cannot be calculated,

explicitly state

"NOT MEASURABLE"

instead of inventing a value.

====================================================
RULE #23
====================================================

Never hardcode:

Repository size

Number of files

Number of modules

Coverage

Documentation %

Complexity

Risk score

Release score

Everything must be computed from the repository..
