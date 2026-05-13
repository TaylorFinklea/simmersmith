<script lang="ts">
    import type { PageData } from './$types';

    let { data }: { data: PageData } = $props();
    let usage = $derived(data.usage);

    const actionLabels: Record<string, string> = {
        ai_generate: 'AI plans',
        pricing_fetch: 'Price fetches',
        rebalance_day: 'Day rebalances',
        recipe_import: 'Recipe imports'
    };

    function label(action: string) {
        return actionLabels[action] ?? action.replaceAll('_', ' ');
    }

    function money(n: number) {
        return `$${n.toFixed(2)}`;
    }
</script>

<section>
    <div class="flex items-baseline justify-between flex-wrap gap-4 mb-3">
        <h2 class="text-3xl italic">usage</h2>
        <form method="get" class="flex items-center gap-2 text-sm">
            <label for="period" class="text-ink-soft">Month</label>
            <input
                id="period"
                name="period"
                type="month"
                value={usage.period}
                class="bg-paper-alt border border-rule rounded px-2 py-1 text-ink"
            />
            <button type="submit" class="px-3 py-1 rounded border border-rule text-ink-soft hover:text-ink">
                Refresh
            </button>
        </form>
    </div>
    <div class="hand-rule w-24 mb-6"></div>

    <h3 class="text-sm tracking-wider uppercase text-ink-soft mb-3">totals · {usage.period}</h3>
    {#if Object.keys(usage.totals).length === 0}
        <p class="text-ink-soft mb-8">No activity recorded for this month yet.</p>
    {:else}
        <div class="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
            {#each Object.entries(usage.totals) as [action, total]}
                <div class="bg-paper-alt border border-rule rounded p-4">
                    <div class="text-xs text-ink-soft uppercase tracking-wider">{label(action)}</div>
                    <div class="text-3xl mt-1 font-mono">{total}</div>
                </div>
            {/each}
        </div>
        <div class="mb-10 text-sm text-ink-soft">
            Estimated spend this month:
            <span class="text-ember font-mono ml-1">{money(usage.estimated_cost_usd)}</span>
        </div>
    {/if}

    <h3 class="text-sm tracking-wider uppercase text-ink-soft mb-3">by user</h3>
    {#if usage.by_user.length === 0}
        <p class="text-ink-soft">No users have AI activity this month.</p>
    {:else}
        <div class="overflow-x-auto">
            <table class="w-full text-sm">
                <thead class="text-left text-ink-soft uppercase tracking-wider text-xs">
                    <tr>
                        <th class="py-2 pr-4">User</th>
                        {#each Object.keys(usage.totals) as action}
                            <th class="py-2 px-2 text-right">{label(action)}</th>
                        {/each}
                        <th class="py-2 px-4 text-right">Total</th>
                        <th class="py-2 pl-4 text-right">Est. spend</th>
                    </tr>
                </thead>
                <tbody>
                    {#each usage.by_user as user}
                        <tr class="border-t border-rule hover:bg-paper-alt/60">
                            <td class="py-2 pr-4">
                                <a href="/users/{user.user_id}" class="hover:text-ember">
                                    <div class="text-ink">{user.email || '(no email)'}</div>
                                    {#if user.display_name}
                                        <div class="text-xs text-ink-faint">{user.display_name}</div>
                                    {/if}
                                </a>
                            </td>
                            {#each Object.keys(usage.totals) as action}
                                <td class="py-2 px-2 text-right font-mono">
                                    {user.totals[action] ?? 0}
                                </td>
                            {/each}
                            <td class="py-2 px-4 text-right font-mono text-ember">{user.total}</td>
                            <td class="py-2 pl-4 text-right font-mono text-ink-soft">
                                {money(user.estimated_cost_usd)}
                            </td>
                        </tr>
                    {/each}
                </tbody>
            </table>
        </div>
    {/if}
</section>
