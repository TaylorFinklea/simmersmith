<script lang="ts">
    import type { PageData, ActionData } from './$types';
    import { invalidateAll } from '$app/navigation';

    let { data, form }: { data: PageData; form: ActionData } = $props();
    let s = $derived(data.settings);

    function fieldBadge(overridden: boolean) {
        return overridden
            ? 'text-xs px-2 py-0.5 rounded bg-ember/20 text-ember'
            : 'text-xs px-2 py-0.5 rounded bg-paper-alt text-ink-faint';
    }
</script>

<section>
    <h2 class="text-3xl italic mb-1">settings</h2>
    <div class="hand-rule w-24 mb-6"></div>
    <p class="text-sm text-ink-soft mb-8">
        Values flagged <span class="text-ember">override</span> live in the database
        (<code class="text-xs">server_settings</code> table). The "default" column shows
        what falls through if the override is removed.
    </p>

    {#if form?.ok}
        <div class="mb-6 p-3 rounded border border-success/40 bg-success/10 text-success">
            Saved.
        </div>
    {/if}
    {#if form?.message}
        <div class="mb-6 p-3 rounded border border-destructive/40 bg-destructive/10 text-destructive">
            {form.message}
        </div>
    {/if}

    <!-- Free-tier limits -->
    <div class="bg-paper-alt border border-rule rounded p-5 mb-8">
        <div class="flex items-baseline justify-between mb-3">
            <h3 class="text-xl italic">Free-tier limits</h3>
            <span class={fieldBadge(s.free_tier_limits.overridden)}>
                {s.free_tier_limits.overridden ? 'override' : 'default'}
            </span>
        </div>
        <p class="text-xs text-ink-soft mb-4">
            Monthly per-user caps for non-pro users. Pro / trial users bypass the gate
            entirely (counters still accrue for visibility).
        </p>
        <form method="post" action="?/save-limits" class="space-y-3">
            {#each Object.entries(s.free_tier_limits.value) as [action, limit]}
                <div class="flex items-center gap-3">
                    <label for="limit-{action}" class="text-sm flex-1 text-ink-soft">
                        {action.replaceAll('_', ' ')}
                    </label>
                    <input
                        id="limit-{action}"
                        name="limit:{action}"
                        type="number"
                        min="0"
                        value={limit}
                        class="w-24 bg-paper border border-rule rounded px-2 py-1 text-right font-mono"
                    />
                    <span class="text-xs text-ink-faint w-20">
                        default {s.free_tier_limits.default[action] ?? 0}
                    </span>
                </div>
            {/each}
            <div class="flex gap-2 pt-2">
                <button
                    type="submit"
                    class="px-4 py-2 rounded bg-ember text-paper font-medium hover:bg-ember-hot"
                >
                    Save limits
                </button>
                <button
                    type="submit"
                    name="reset"
                    value="1"
                    class="px-4 py-2 rounded border border-rule text-ink-soft hover:text-ink"
                >
                    Reset to defaults
                </button>
            </div>
        </form>
    </div>

    <!-- AI model defaults -->
    <div class="bg-paper-alt border border-rule rounded p-5 mb-8">
        <h3 class="text-xl italic mb-3">AI model defaults</h3>
        <p class="text-xs text-ink-soft mb-4">
            Fall-through models used when a user has no per-profile override. iOS callers
            can still pick a different model in Settings → AI.
        </p>
        <form method="post" action="?/save-models" class="space-y-4">
            <div>
                <div class="flex items-baseline justify-between mb-1">
                    <label for="ai_openai_model" class="text-sm text-ink-soft">OpenAI model</label>
                    <span class={fieldBadge(s.ai_openai_model.overridden)}>
                        {s.ai_openai_model.overridden ? 'override' : 'default'}
                    </span>
                </div>
                <input
                    id="ai_openai_model"
                    name="ai_openai_model"
                    type="text"
                    value={s.ai_openai_model.value}
                    placeholder={s.ai_openai_model.default}
                    class="w-full bg-paper border border-rule rounded px-3 py-2 font-mono text-sm"
                />
                <label class="text-xs text-ink-faint mt-1 inline-flex items-center gap-1">
                    <input type="checkbox" name="reset_openai" value="1" /> Reset to default
                    ({s.ai_openai_model.default})
                </label>
            </div>

            <div>
                <div class="flex items-baseline justify-between mb-1">
                    <label for="ai_anthropic_model" class="text-sm text-ink-soft">Anthropic model</label>
                    <span class={fieldBadge(s.ai_anthropic_model.overridden)}>
                        {s.ai_anthropic_model.overridden ? 'override' : 'default'}
                    </span>
                </div>
                <input
                    id="ai_anthropic_model"
                    name="ai_anthropic_model"
                    type="text"
                    value={s.ai_anthropic_model.value}
                    placeholder={s.ai_anthropic_model.default}
                    class="w-full bg-paper border border-rule rounded px-3 py-2 font-mono text-sm"
                />
                <label class="text-xs text-ink-faint mt-1 inline-flex items-center gap-1">
                    <input type="checkbox" name="reset_anthropic" value="1" /> Reset to default
                    ({s.ai_anthropic_model.default})
                </label>
            </div>
            <button
                type="submit"
                class="px-4 py-2 rounded bg-ember text-paper font-medium hover:bg-ember-hot"
            >
                Save models
            </button>
        </form>
    </div>

    <!-- Trial mode -->
    <div class="bg-paper-alt border border-rule rounded p-5 mb-8">
        <div class="flex items-baseline justify-between mb-3">
            <h3 class="text-xl italic">Trial mode</h3>
            <span class={fieldBadge(s.trial_mode_enabled.overridden)}>
                {s.trial_mode_enabled.overridden ? 'override' : 'default'}
            </span>
        </div>
        <p class="text-xs text-ink-soft mb-4">
            When on, every user gets Pro for free (paywall bypassed). Counters still
            accrue so usage is visible. Default comes from the
            <code class="text-xs">SIMMERSMITH_TRIAL_MODE_ENABLED</code> env var
            ({s.trial_mode_enabled.default ? 'on' : 'off'}).
        </p>
        <form method="post" action="?/save-trial" class="flex items-center gap-3">
            <label class="inline-flex items-center gap-2 text-sm">
                <input
                    type="checkbox"
                    name="value"
                    checked={s.trial_mode_enabled.value}
                    class="accent-ember"
                />
                <span>Trial mode {s.trial_mode_enabled.value ? 'on' : 'off'}</span>
            </label>
            <button
                type="submit"
                class="px-4 py-2 rounded bg-ember text-paper font-medium hover:bg-ember-hot"
            >
                Save
            </button>
            <button
                type="submit"
                name="reset"
                value="1"
                class="px-4 py-2 rounded border border-rule text-ink-soft hover:text-ink"
            >
                Reset to env default
            </button>
        </form>
    </div>
</section>
