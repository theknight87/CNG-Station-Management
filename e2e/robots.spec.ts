import { expect, test } from 'playwright/test'
test('robots disallows indexing', async ({ request }) => { const response = await request.get('/robots.txt'); expect(response.ok()).toBeTruthy(); expect(response.headers()['content-type']).toContain('text/plain'); expect(await response.text()).toContain('Disallow: /') })
