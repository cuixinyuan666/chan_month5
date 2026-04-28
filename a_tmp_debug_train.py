import faulthandler, time
faulthandler.enable()
faulthandler.dump_traceback_later(20, repeat=True)
print('before-import', flush=True)
from a_replay_parts.a_rld_train_backend import RldTrainAppState, RldTrainInitReq
print('after-import', flush=True)
state = RldTrainAppState()
req = RldTrainInitReq(code='001312', begin_date='2026-04-21', end_date='2026-04-24', autype='qfq', lv_list=['day','60m','15m'], chan_config={'chan_algo':'classic'}, initial_cash=100000)
print('init-start', flush=True)
state.init(req)
print('init-done', flush=True)
payload = state.build_payload()
print('payload-done', payload['ready'], payload['time'], len(payload['levels']), flush=True)
