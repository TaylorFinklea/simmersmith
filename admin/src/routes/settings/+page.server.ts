import { error, fail } from '@sveltejs/kit';
import { adminApi, AdminApiError } from '$lib/server/api';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ platform }) => {
    try {
        const settings = await adminApi.settings(platform);
        return { settings };
    } catch (err) {
        if (err instanceof AdminApiError) {
            throw error(err.status === 403 ? 403 : 502, err.message);
        }
        throw err;
    }
};

export const actions: Actions = {
    'save-limits': async ({ request, platform }) => {
        const form = await request.formData();
        const reset = form.get('reset') === '1';
        if (reset) {
            try {
                await adminApi.patchSettings(platform, { free_tier_limits: null });
            } catch (err) {
                return fail(502, { message: err instanceof Error ? err.message : 'error' });
            }
            return { ok: true };
        }

        const limits: Record<string, number> = {};
        for (const [key, value] of form.entries()) {
            if (!key.startsWith('limit:')) continue;
            const action = key.slice('limit:'.length);
            const parsed = Number.parseInt(String(value), 10);
            if (!Number.isFinite(parsed) || parsed < 0) {
                return fail(400, { message: `Invalid limit for ${action}` });
            }
            limits[action] = parsed;
        }
        try {
            await adminApi.patchSettings(platform, { free_tier_limits: limits });
        } catch (err) {
            return fail(502, { message: err instanceof Error ? err.message : 'error' });
        }
        return { ok: true };
    },

    'save-models': async ({ request, platform }) => {
        const form = await request.formData();
        const patch: {
            ai_openai_model?: string | null;
            ai_anthropic_model?: string | null;
        } = {};
        const openai = String(form.get('ai_openai_model') ?? '').trim();
        const anthropic = String(form.get('ai_anthropic_model') ?? '').trim();
        const resetOpenai = form.get('reset_openai') === '1';
        const resetAnthropic = form.get('reset_anthropic') === '1';
        if (resetOpenai) {
            patch.ai_openai_model = null;
        } else if (openai) {
            patch.ai_openai_model = openai;
        }
        if (resetAnthropic) {
            patch.ai_anthropic_model = null;
        } else if (anthropic) {
            patch.ai_anthropic_model = anthropic;
        }
        if (Object.keys(patch).length === 0) {
            return { ok: true };
        }
        try {
            await adminApi.patchSettings(platform, patch);
        } catch (err) {
            return fail(502, { message: err instanceof Error ? err.message : 'error' });
        }
        return { ok: true };
    },

    'save-trial': async ({ request, platform }) => {
        const form = await request.formData();
        const reset = form.get('reset') === '1';
        const value = form.get('value') === 'on';
        try {
            await adminApi.patchSettings(platform, {
                trial_mode_enabled: reset ? null : value
            });
        } catch (err) {
            return fail(502, { message: err instanceof Error ? err.message : 'error' });
        }
        return { ok: true };
    }
};
