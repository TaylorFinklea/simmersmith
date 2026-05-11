<script lang="ts">
    import '../app.css';
    import { page } from '$app/stores';

    let { children } = $props();

    const navItems = [
        { href: '/', label: 'Usage' },
        { href: '/users', label: 'Users' },
        { href: '/settings', label: 'Settings' }
    ];

    function isActive(href: string, current: string) {
        if (href === '/') return current === '/';
        return current.startsWith(href);
    }
</script>

<div class="min-h-screen flex flex-col">
    <header class="border-b border-rule">
        <div class="mx-auto max-w-5xl px-6 py-5 flex items-baseline justify-between gap-6">
            <div>
                <h1 class="text-2xl italic font-medium">
                    simmer<span class="text-ember">·</span>smith
                </h1>
                <p class="text-sm text-ink-soft uppercase tracking-wider mt-1">admin</p>
            </div>
            <nav class="flex gap-1 text-sm">
                {#each navItems as item}
                    <a
                        href={item.href}
                        class="px-3 py-2 rounded transition-colors {isActive(
                            item.href,
                            $page.url.pathname
                        )
                            ? 'text-ember bg-paper-alt'
                            : 'text-ink-soft hover:text-ink hover:bg-paper-alt/60'}"
                    >
                        {item.label}
                    </a>
                {/each}
            </nav>
        </div>
    </header>

    <main class="flex-1">
        <div class="mx-auto max-w-5xl px-6 py-8">
            {@render children()}
        </div>
    </main>

    <footer class="border-t border-rule mt-8">
        <div class="mx-auto max-w-5xl px-6 py-4 text-xs text-ink-faint">
            Restricted access. SimmerSmith admin console.
        </div>
    </footer>
</div>
