// The official SDK owns the browser flow, token verification, refresh and revocation.
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';
import { homedir } from 'node:os';
import { join } from 'node:path';

const base = join(homedir(), 'Library/Application Support/OpenLink Tuner');
const sdk = join(base, 'plan-sdk-0a36fefeb913055c8c7a1a29b63d82b96b2e841a/packages/local/dist/index.js');

async function run() {
  const { createChatGPT } = await import(pathToFileURL(sdk).href);
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const { action, secret, instructions, input } = JSON.parse(Buffer.concat(chunks));
  const key = Buffer.from(secret, 'base64');
  const client = createChatGPT({
    appName: 'OpenLink Tuner', appId: 'openlink-tuner', sendHostId: true,
    redirectPort: 0, storageDir: join(base, 'ChatGPT Account'),
    openBrowser: async url => {
      if (new URL(url).origin !== 'https://auth.openai.com') throw Error('Unexpected authorization destination');
      await promisify(execFile)('/usr/bin/open', [url]);
    },
    credentialEncryption: {
      id: 'openlink-keychain-aes256gcm-v1',
      isAvailable: () => key.length === 32,
      encrypt: text => {
        const iv = randomBytes(12);
        const cipher = createCipheriv('aes-256-gcm', key, iv);
        const ciphertext = Buffer.concat([cipher.update(text, 'utf8'), cipher.final()]);
        return Buffer.concat([iv, cipher.getAuthTag(), ciphertext]);
      },
      decrypt: data => {
        const buf = Buffer.from(data);
        const decipher = createDecipheriv('aes-256-gcm', key, buf.subarray(0, 12));
        decipher.setAuthTag(buf.subarray(12, 28));
        return Buffer.concat([decipher.update(buf.subarray(28)), decipher.final()]).toString('utf8');
      }
    }
  });
  if (action === 'disconnect') await client.disconnect();
  const state = action === 'signin' ? await client.signIn({reconsent:true}) : await client.getSession();
  if (action === 'ask') {
    if (!state.sharing) return {error:'Connect ChatGPT and grant plan usage first.'};
    const models = await client.listModels({signal:AbortSignal.timeout(30000)});
    if (!models.length) return {error:'This connection has no available models.'};
    const result = await client.streamResponse({model:models[0].slug, input, instructions, signal:AbortSignal.timeout(120000)});
    return {text:result.text};
  }
  return {sharing:state.sharing, connected:state.status === 'connected', label:state.identity?.email ?? state.profileLabel ?? ''};
}
try { console.log(JSON.stringify(await run())); }
catch (e) {
  const message = e.code === 'ERR_MODULE_NOT_FOUND' ? 'Install the ChatGPT plan runtime using src/scripts/install-chatgpt-plan.sh.' :
    e.name === 'ChatGPTError' ? e.message : 'ChatGPT plan connection failed. Check the local runtime and try again.';
  console.log(JSON.stringify({error:message}));
}
