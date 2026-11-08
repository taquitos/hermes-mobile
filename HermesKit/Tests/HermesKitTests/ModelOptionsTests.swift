import Foundation
import Testing

@testable import HermesKit

struct ModelOptionsTests {
  @Test func decodesProvidersModelsAndCapabilities() throws {
    let json = #"""
    {
      "model": "claude-opus-4-8",
      "provider": "anthropic",
      "providers": [
        {
          "name": "Anthropic", "slug": "anthropic", "authenticated": true,
          "models": ["claude-opus-4-8", "claude-haiku-4-5"],
          "capabilities": {
            "claude-opus-4-8": {"fast": false, "reasoning": true},
            "claude-haiku-4-5": {"fast": true, "reasoning": false}
          }
        },
        { "name": "OpenAI", "slug": "openai", "models": [], "authenticated": false, "warning": "paste OPENAI_API_KEY to activate" }
      ]
    }
    """#
    let options = try JSONDecoder().decode(ModelOptions.self, from: Data(json.utf8))

    #expect(options.currentModel == "claude-opus-4-8")
    #expect(options.providers.count == 2)
    // Configured providers first, then unconfigured (with a hint); both kept.
    #expect(options.orderedProviders.map(\.name) == ["Anthropic", "OpenAI"])
    #expect(options.orderedProviders.map(\.isConfigured) == [true, false])
    #expect(options.providers.first(where: { $0.name == "OpenAI" })?.warning == "paste OPENAI_API_KEY to activate")
  }

  @Test func orderedProvidersPutsConfiguredFirstAndDropsEmptyNoHint() {
    let options = ModelOptions(providers: [
      .init(name: "Unconfigured", slug: "u", models: [], authenticated: false, warning: "configure me"),
      .init(name: "Configured", slug: "c", models: ["m"], authenticated: true),
      .init(name: "Empty", slug: "e", models: [], authenticated: false), // no models, no hint → dropped
    ])
    #expect(options.orderedProviders.map(\.name) == ["Configured", "Unconfigured"])
  }

  @Test func supportsReasoningReflectsPerModelCapability() {
    let options = ModelOptions(
      providers: [.init(
        name: "Anthropic", slug: "anthropic",
        models: ["opus", "haiku"], authenticated: true,
        capabilities: ["opus": .init(reasoning: true), "haiku": .init(reasoning: false)]
      )],
      currentModel: "opus"
    )
    #expect(options.supportsReasoning("opus") == true)
    #expect(options.supportsReasoning("haiku") == false)
    // Unknown model / nil → default true (don't hide the control on unknowns).
    #expect(options.supportsReasoning("mystery") == true)
    #expect(options.supportsReasoning(nil) == true)
  }

  @Test func reasoningLadderIsTheFullUpstreamScale() {
    #expect(ModelOptions.reasoningEfforts == [
      "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
    ])
    #expect(ModelOptions.reasoningEfforts.first == "none")
    #expect(ModelOptions.reasoningEfforts.last == "ultra")
  }

  @Test func offeredEffortsReturnsFullLadderWhenExtendedSupported() {
    #expect(ModelOptions.offeredEfforts(extendedSupported: true) == ModelOptions.reasoningEfforts)
  }

  @Test func offeredEffortsDropsExactlyMaxAndUltraWhenLatched() {
    let offered = ModelOptions.offeredEfforts(extendedSupported: false)
    #expect(offered == ["none", "minimal", "low", "medium", "high", "xhigh"])
    // Only the extended levels are removed; the rest keeps ladder order.
    #expect(Set(ModelOptions.reasoningEfforts).subtracting(offered) == ModelOptions.extendedReasoningEfforts)
    #expect(offered == ModelOptions.reasoningEfforts.filter { offered.contains($0) })
  }

  @Test func extendedEffortsAreASubsetOfTheLadder() {
    #expect(ModelOptions.extendedReasoningEfforts.isSubset(of: Set(ModelOptions.reasoningEfforts)))
    #expect(ModelOptions.extendedReasoningEfforts == ["max", "ultra"])
  }

  // MARK: filteredProviders(matching:)

  private let searchableOptions = ModelOptions(providers: [
    .init(name: "Anthropic", slug: "anthropic", models: ["claude-opus-4-8", "claude-haiku-4-5"], authenticated: true),
    .init(name: "DeepSeek", slug: "deepseek", models: ["deepseek-v4-flash", "deepseek-reasoner"], authenticated: true),
    .init(name: "OpenAI", slug: "openai", models: ["gpt-5.6", "gpt-5.6-mini"], authenticated: true),
    .init(name: "Groq", slug: "groq", models: [], authenticated: false, warning: "paste GROQ_API_KEY to activate"),
  ])

  @Test func emptyQueryReturnsTheFullOrderedList() {
    #expect(searchableOptions.filteredProviders(matching: "").map(\.name) ==
      searchableOptions.orderedProviders.map(\.name))
    #expect(searchableOptions.filteredProviders(matching: "   ").map(\.name) ==
      searchableOptions.orderedProviders.map(\.name))
  }

  @Test func modelNameSubstringMatchKeepsOnlyMatchingModelsWithinTheirProvider() {
    // "dee" matches both DeepSeek models but no other provider's models.
    let result = searchableOptions.filteredProviders(matching: "dee")
    #expect(result.map(\.name) == ["DeepSeek"])
    #expect(result.first?.models == ["deepseek-v4-flash", "deepseek-reasoner"])
  }

  @Test func modelNameMatchDropsNonMatchingModelsButKeepsTheProviderSection() {
    let result = searchableOptions.filteredProviders(matching: "reasoner")
    #expect(result.map(\.name) == ["DeepSeek"])
    #expect(result.first?.models == ["deepseek-reasoner"])
  }

  @Test func providerNameMatchKeepsAllOfThatProvidersModels() {
    // "openai" matches the provider name, so every OpenAI model survives even though
    // none of them contain the substring.
    let result = searchableOptions.filteredProviders(matching: "openai")
    #expect(result.map(\.name) == ["OpenAI"])
    #expect(result.first?.models == ["gpt-5.6", "gpt-5.6-mini"])
  }

  @Test func unconfiguredProviderWithWarningMatchesByNameOnly() {
    // Groq has no models, so only a provider-name match can surface it.
    let result = searchableOptions.filteredProviders(matching: "groq")
    #expect(result.map(\.name) == ["Groq"])
    #expect(result.first?.models.isEmpty == true)
  }

  @Test func matchingIsCaseAndDiacriticInsensitive() {
    #expect(searchableOptions.filteredProviders(matching: "DEEP").map(\.name) == ["DeepSeek"])
    #expect(searchableOptions.filteredProviders(matching: "claude").map(\.name) == ["Anthropic"])
  }

  @Test func noMatchReturnsAnEmptyList() {
    #expect(searchableOptions.filteredProviders(matching: "zzz").isEmpty)
  }

  @Test func filteringPreservesProviderOrdering() {
    // "a" matches Anthropic and OpenAI by provider name and DeepSeek by model name; all
    // three configured providers survive in their original (configured-first) order.
    let result = searchableOptions.filteredProviders(matching: "a")
    #expect(result.map(\.name) == ["Anthropic", "DeepSeek", "OpenAI"])
  }

  // MARK: Picker hide list (Nous Portal, GitHub Copilot)

  /// A payload shaped like the live `model.options` response (live row names verified against
  /// `GET /api/model/options`): the hidden rows come back configured (signed in) and
  /// unconfigured-with-hint, and lookalike rows share their name/slug family.
  private let nousBearingOptions = ModelOptions(providers: [
    .init(name: "Anthropic", slug: "anthropic", models: ["claude-opus-4-8"], authenticated: true),
    .init(name: "Nous Portal", slug: "nous",
          models: ["nova-pro-v2", "llama-4-maverick"], authenticated: true,
          capabilities: ["nova-pro-v2": .init(reasoning: true)]),
    .init(name: "Nous Portal (SSO)", slug: "nous", models: [], authenticated: false,
          warning: "sign in to nous to activate"),
    .init(name: "Nous Proxy", slug: "custom:nous-proxy", models: ["nous-proxy-large"],
          authenticated: true),
    .init(name: "Ollama Cloud", slug: nil, models: ["qwen3-32b"], authenticated: true),
    .init(name: "GitHub Copilot", slug: "copilot", models: ["gpt-5.1-codex"], authenticated: true),
    .init(name: "GitHub Copilot ACP", slug: "copilot-acp", models: [], authenticated: false,
          warning: "sign in to GitHub to activate"),
    .init(name: "GitHub Copilot Enterprise", slug: "copilot-enterprise",
          models: ["gpt-5.1"], authenticated: true),
  ])

  @Test func hiddenRowsNeverReachThePicker() {
    #expect(nousBearingOptions.orderedProviders.map(\.name)
              == ["Anthropic", "Nous Proxy", "Ollama Cloud", "GitHub Copilot Enterprise"])
  }

  @Test func hiddenRowsStayHiddenUnderSearch() {
    // Section titles, model names, and hint text all used to surface these sections.
    #expect(nousBearingOptions.filteredProviders(matching: "nous portal").isEmpty)
    #expect(nousBearingOptions.filteredProviders(matching: "nova").isEmpty)
    #expect(nousBearingOptions.filteredProviders(matching: "sign in to nous").isEmpty)
    // The visible lookalike still matches its own name; the hidden rows never join it.
    #expect(nousBearingOptions.filteredProviders(matching: "github copilot").map(\.name)
              == ["GitHub Copilot Enterprise"])
    #expect(nousBearingOptions.filteredProviders(matching: "gpt-5.1-codex").isEmpty)
    #expect(nousBearingOptions.filteredProviders(matching: "sign in to GitHub").isEmpty)
    // The unconfigured lock rows are gone too, not just the configured ones.
    #expect(!nousBearingOptions.filteredProviders(matching: "a").contains {
      ["nous", "copilot", "copilot-acp"].contains($0.slug ?? "")
    })
  }

  @Test func hideMatchesSlugFirstAndLeavesSimilarlyNamedCustomRowsAlone() {
    // Same display-name / slug families, different slugs → visible.
    #expect(nousBearingOptions.filteredProviders(matching: "proxy").map(\.name) == ["Nous Proxy"])
    #expect(nousBearingOptions.filteredProviders(matching: "copilot").map(\.name)
              == ["GitHub Copilot Enterprise"])
    // Hide list is slug-exact, not a prefix or substring.
    #expect(ModelOptions.isHiddenPickerProvider(slug: "custom:nous", name: "My Nous") == false)
    #expect(ModelOptions.isHiddenPickerProvider(slug: "copilot-enterprise",
                                               name: "Anything") == false)
    #expect(ModelOptions.isHiddenPickerProvider(slug: "nous", name: "Anything") == true)
    #expect(ModelOptions.isHiddenPickerProvider(slug: "NOUS", name: "Anything") == true)
    #expect(ModelOptions.isHiddenPickerProvider(slug: "copilot", name: "Anything") == true)
    #expect(ModelOptions.isHiddenPickerProvider(slug: "copilot-acp", name: "Anything") == true)
  }

  @Test func nameFallbackOnlyAppliesWhenTheRowHasNoUsableSlug() {
    #expect(ModelOptions.isHiddenPickerProvider(slug: nil, name: "Nous Portal") == true)
    #expect(ModelOptions.isHiddenPickerProvider(slug: nil, name: "GitHub Copilot") == true)
    #expect(ModelOptions.isHiddenPickerProvider(slug: nil, name: "GitHub Copilot ACP") == true)
    #expect(ModelOptions.isHiddenPickerProvider(slug: "   ", name: "Nous") == true)
    // Exact-name match only: a prefixed name with no slug stays visible.
    #expect(ModelOptions.isHiddenPickerProvider(slug: nil, name: "Nous Portal EU Mirror") == false)
    #expect(ModelOptions.isHiddenPickerProvider(slug: nil,
                                               name: "GitHub Copilot Enterprise") == false)
    // A slug-carrying row is decided by its slug alone.
    #expect(ModelOptions.isHiddenPickerProvider(slug: "openai", name: "Nous Portal") == false)
    #expect(ModelOptions.isHiddenPickerProvider(slug: "gh-enterprise",
                                               name: "GitHub Copilot") == false)
  }

  @Test func hidingIsPickerSideOnlyTheDecodedPayloadKeepsTheRow() {
    let json = #"""
    {"model": "nova-pro-v2", "providers": [
      {"name": "Nous Portal", "slug": "nous", "authenticated": true,
       "models": ["nova-pro-v2"], "capabilities": {"nova-pro-v2": {"reasoning": true}}},
      {"name": "GitHub Copilot", "slug": "copilot", "authenticated": true,
       "models": ["gpt-5.1-codex"], "capabilities": {"gpt-5.1-codex": {"reasoning": false}}}
    ]}
    """#
    let options = try! JSONDecoder().decode(ModelOptions.self, from: Data(json.utf8))
    #expect(options.providers.map(\.name) == ["Nous Portal", "GitHub Copilot"])  // payload untouched
    #expect(options.orderedProviders.isEmpty)                                     // picker hides both
    // Capability lookup reads the raw list, so a hidden provider's model still resolves its flag.
    #expect(options.supportsReasoning("nova-pro-v2") == true)
    #expect(options.supportsReasoning("gpt-5.1-codex") == false)
  }

  @Test func filteringKeepsAliases() {
    let options = ModelOptions(providers: [
      .init(name: "Local", slug: "local", models: ["qwen"], authenticated: true, aliases: ["custom:local"]),
    ])
    #expect(options.filteredProviders(matching: "qwen").first?.aliases == ["custom:local"])
  }

  // MARK: currentProvider decode

  private func decode(_ json: String) throws -> ModelOptions {
    try JSONDecoder().decode(ModelOptions.self, from: Data(json.utf8))
  }

  @Test func decodesTopLevelProviderAsCurrentProvider() throws {
    let options = try decode(#"{"model": "gpt-5.6", "provider": "openrouter", "providers": []}"#)
    #expect(options.currentModel == "gpt-5.6")
    #expect(options.currentProvider == "openrouter")
  }

  @Test func missingProviderDecodesAsNil() throws {
    let options = try decode(#"{"model": "gpt-5.6", "providers": []}"#)
    #expect(options.currentModel == "gpt-5.6")
    #expect(options.currentProvider == nil)
  }

  @Test func malformedOrBlankProviderIsIgnored() throws {
    for raw in [#"42"#, #"{"slug": "x"}"#, #"null"#, #""""#, #""   ""#] {
      let options = try decode(#"{"model": "m", "provider": \#(raw), "providers": [{"name": "A", "slug": "a", "models": ["m"], "authenticated": true}]}"#)
      #expect(options.currentProvider == nil, "provider: \(raw)")
      // The rest of the payload still decodes.
      #expect(options.currentModel == "m")
      #expect(options.providers.map(\.slug) == ["a"])
    }
  }

  @Test func decodesProviderAliasesLeniently() throws {
    let options = try decode(#"""
    {"providers": [
      {"name": "My Box", "slug": "mybox", "models": ["m"], "authenticated": true, "aliases": ["custom:mybox", "mybox"]},
      {"name": "Bad", "slug": "bad", "models": ["m"], "authenticated": true, "aliases": "nope"},
      {"name": "None", "slug": "none", "models": ["m"], "authenticated": true}
    ]}
    """#)
    #expect(options.providers.map(\.aliases) == [["custom:mybox", "mybox"], [], []])
  }

  // MARK: isCurrent(model:in:currentModel:)

  private let sharedModelOptions = ModelOptions(
    providers: [
      .init(name: "OpenAI", slug: "openai", models: ["gpt-5.6"], authenticated: true),
      .init(name: "OpenRouter", slug: "openrouter", models: ["gpt-5.6", "deepseek-v4"], authenticated: true),
    ],
    currentModel: "gpt-5.6",
    currentProvider: "openrouter"
  )

  @Test func sameModelUnderTwoProvidersOnlyTheMatchingProviderIsCurrent() {
    let openAI = sharedModelOptions.providers[0]
    let openRouter = sharedModelOptions.providers[1]
    #expect(sharedModelOptions.isCurrent(model: "gpt-5.6", in: openRouter, currentModel: "gpt-5.6"))
    #expect(!sharedModelOptions.isCurrent(model: "gpt-5.6", in: openAI, currentModel: "gpt-5.6"))
    #expect(!sharedModelOptions.isCurrent(model: "deepseek-v4", in: openRouter, currentModel: "gpt-5.6"))
  }

  @Test func absentCurrentProviderFallsBackToModelOnly() {
    var options = sharedModelOptions
    options.currentProvider = nil
    #expect(options.isCurrent(model: "gpt-5.6", in: options.providers[0], currentModel: "gpt-5.6"))
    #expect(options.isCurrent(model: "gpt-5.6", in: options.providers[1], currentModel: "gpt-5.6"))
    #expect(!options.isCurrent(model: "deepseek-v4", in: options.providers[1], currentModel: "gpt-5.6"))
  }

  @Test func nilCurrentModelMatchesNothing() {
    #expect(!sharedModelOptions.isCurrent(model: "gpt-5.6", in: sharedModelOptions.providers[1], currentModel: nil))
  }

  @Test func currentModelParameterWinsOverPayloadModel() {
    // The chat's optimistic pick is the display truth, not the payload's `model`.
    let openRouter = sharedModelOptions.providers[1]
    #expect(sharedModelOptions.isCurrent(model: "deepseek-v4", in: openRouter, currentModel: "deepseek-v4"))
    #expect(!sharedModelOptions.isCurrent(model: "gpt-5.6", in: openRouter, currentModel: "deepseek-v4"))
  }

  @Test func currentProviderMatchesSlugNameOrAlias() {
    let custom = ModelOptions.Provider(
      name: "My Box", slug: "mybox", models: ["qwen"], authenticated: true, aliases: ["custom:mybox"]
    )
    #expect(custom.matches(providerID: "mybox"))
    #expect(custom.matches(providerID: "My Box"))
    #expect(custom.matches(providerID: "custom:mybox"))
    #expect(!custom.matches(providerID: "openrouter"))
    #expect(!custom.matches(providerID: ""))
    let options = ModelOptions(providers: [custom], currentModel: "qwen", currentProvider: "custom:mybox")
    #expect(options.isCurrent(model: "qwen", in: custom, currentModel: "qwen"))
  }

  @Test func currentProviderMatchingNoRowMarksNothingCurrent() {
    // Desktop parity: a provider-bound match never falls back to model-only.
    var options = sharedModelOptions
    options.currentProvider = "anthropic"
    #expect(options.providers.allSatisfy { !options.isCurrent(model: "gpt-5.6", in: $0, currentModel: "gpt-5.6") })
  }
}
