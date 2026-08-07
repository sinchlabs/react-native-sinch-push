import { create } from '@bufbuild/protobuf';
import {
  IssueAnonymousTokenRequestSchema,
  IssueTokenWithSignedUuidResponseSchema,
} from '../src/generated/sinch/chat/sdk/v1alpha2/sdk_pb';
import { AuthModel, DefaultAuthRepository } from '../src/api/authRepository';
import { fakeTransport } from './fakeTransport';

const JWT_FIXTURE =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.' +
  'eyJ1dWlkIjoiYW5vbi11c2VyLWZkZWFkYmVlZiJ9.' +
  'signature';

const config = {
  clientID: 'client-1',
  projectID: 'project-1',
  configID: 'config-1',
  region: 'eu1' as const,
};

describe('DefaultAuthRepository.createAnonymousToken', () => {
  it('builds an AuthModel with kind="anonymous" and the issued access token', async () => {
    const seen: Array<{ method: string; request: any }> = [];
    const transport = fakeTransport((method, request) => {
      seen.push({ method, request });
      return create(IssueTokenWithSignedUuidResponseSchema, { accessToken: JWT_FIXTURE });
    });
    const repo = new DefaultAuthRepository(transport);

    const auth = await repo.createAnonymousToken(config);

    expect(auth).toBeInstanceOf(AuthModel);
    expect(auth.accessToken).toBe(JWT_FIXTURE);
    expect(auth.sinchIdentity).toEqual({ kind: 'anonymous' });
    expect(auth.clientID).toBe(config.clientID);
    expect(auth.projectID).toBe(config.projectID);
    expect(auth.configID).toBe(config.configID);
    expect(auth.region).toBe(config.region);

    expect(seen).toHaveLength(1);
    expect(seen[0]?.method).toBe('IssueAnonymousToken');
    expect(seen[0]?.request).toEqual(
      create(IssueAnonymousTokenRequestSchema, {
        projectId: config.projectID,
        clientId: config.clientID,
      }),
    );
  });
});

describe('DefaultAuthRepository.createSignedToken', () => {
  it('builds an AuthModel with kind="selfSigned" carrying userID and signedUserID', async () => {
    const seen: Array<{ method: string; request: any }> = [];
    const transport = fakeTransport((method, request) => {
      seen.push({ method, request });
      return create(IssueTokenWithSignedUuidResponseSchema, { accessToken: JWT_FIXTURE });
    });
    const repo = new DefaultAuthRepository(transport);

    const userId = 'alice';
    const signedUserId = 'alice-signed-hex';
    const auth = await repo.createSignedToken(config, userId, signedUserId);

    expect(auth).toBeInstanceOf(AuthModel);
    expect(auth.accessToken).toBe(JWT_FIXTURE);
    expect(auth.sinchIdentity).toEqual({
      kind: 'selfSigned',
      userId,
      signedUserId,
    });
    expect(auth.getUserID()).toBe('anon-user-fdeadbeef');

    expect(seen).toHaveLength(1);
    expect(seen[0]?.method).toBe('IssueTokenWithSignedUuid');
    expect(seen[0]?.request).toMatchObject({
      projectId: config.projectID,
      clientId: config.clientID,
      uuid: userId,
      uuidHash: signedUserId,
    });
  });
});
