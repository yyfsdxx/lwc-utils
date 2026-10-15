/**
 * JUJ082 応募情報検索（JUJ080 から LightningModal として呼び出す）
 * 設計書：JUJ082 応募情報検索 検索処理 v7
 * コメント中の番号は検索処理の章番号に対応する。【要確認】は html・メタデータ・QA の確定後に修正する。
 *
 * 呼出し：Juj082.open({ size: 'large', jigyoKey, jigyoName, basyoName })
 * 戻り値：応募行を選択した場合 { applicationId }、閉じた場合 undefined
 */
import { api } from 'lwc';
import LightningModal from 'lightning/modal';

// ========== Apex（未デプロイのため一時的にコメントアウト。デプロイ後は import を戻し、下のスタブを削除する）==========
// ※ 引数は検索条件の JSON 文字列（conditionJson）。戻り値は検索結果の行リスト。
// import search from '@salesforce/apex/JUJ082Controller.search';

// 【要確認 QA-20】メッセージ文言・ID
const MSG = {
    RANGE: '範囲指定が正しくありません。', // SYSTEM-5104
    NOT_FOUND: '該当する応募情報がありません。'
};

// From／To の組（画面項目名, ラベル, 数値比較か）
const RANGES = [
    ['uketukeNo', '受付番号', true],
    ['torokuNo', '登録番号', false],
    ['shibuCode', '支部コード', false],
    ['sodaninNo', '相談員番号', false]
];

const emptyCondition = () => ({
    uketukeNoFrom: '',
    uketukeNoTo: '',
    torokuNoFrom: '',
    torokuNoTo: '',
    shibuCodeFrom: '',
    shibuCodeTo: '',
    sodaninNoFrom: '',
    sodaninNoTo: '',
    name: ''
});

// ========== スタブ（Apex デプロイ後に削除）==========
const search = async () => [
    { applicationId: 'a00000000000001AAA', uketukeNo: 1, jujishaType: 'MEMBER', jujishaNo: '1000002', name: '佐藤 花子', shibuCode: '002', shibuName: '西支部' },
    { applicationId: 'a00000000000002AAA', uketukeNo: 2, jujishaType: 'MEMBER', jujishaNo: '1000001', name: '山田 太郎', shibuCode: '001', shibuName: '東支部' },
    { applicationId: 'a00000000000003AAA', uketukeNo: 3, jujishaType: 'SODANIN', jujishaNo: '9000001', name: '山田 一郎', shibuCode: null, shibuName: null }
];
// ========== スタブ ここまで ==========

export default class Juj082 extends LightningModal {
    // 呼出し元（JUJ080）からの引継ぎ
    @api jigyoKey; // { jujiJigyoNo, jujiBasyoNo, jisiNendo }
    @api jigyoName; // 従事事業名（結果一覧に画面の値を設定する）
    @api basyoName; // 従事場所名（同上）

    condition = emptyCondition();
    rows = [];
    searched = false; // 検索実行済みか（0件メッセージの表示制御）
    headerMessages = []; // 画面頭部に表示するエラーメッセージ
    isLoading = false;

    // ========== 入力 ==========
    handleConditionChange(event) {
        const field = event.target.dataset.field;
        this.condition = { ...this.condition, [field]: event.detail.value };
    }

    // ========== 1. 検索ボタン押下時 ==========
    async handleSearchClick() {
        this.headerMessages = [];
        // (1) 入力チェック：From ＞ To の場合はエラー（複数項目の関連チェックのため頭部に表示）
        if (!this.validateRanges()) {
            return;
        }
        this.isLoading = true;
        try {
            // (2)〜(7) 検索（従事事業が取得できない場合はサーバ側で 0件を返す）
            const result = await search({ conditionJson: JSON.stringify(this.buildCondition()) });
            // (5) 従事事業名・従事場所名は画面の値を設定する
            this.rows = result.map((row) => ({ ...row, jigyoName: this.jigyoName, basyoName: this.basyoName }));
            this.searched = true;
        } catch (error) {
            this.headerMessages = [error?.body?.message || '予期しないエラーが発生しました。'];
        } finally {
            this.isLoading = false;
        }
    }

    // (1) From／To の範囲チェック
    validateRanges() {
        const c = this.condition;
        const errors = RANGES.filter(([key, , isNumber]) => {
            const from = c[key + 'From'];
            const to = c[key + 'To'];
            if (!from || !to) {
                return false;
            }
            return isNumber ? Number(from) > Number(to) : from > to;
        }).map(([, label]) => `${label}：${MSG.RANGE}`);
        this.headerMessages = errors;
        return errors.length === 0;
    }

    // サーバへ渡す検索条件（従事事業キーは呼出し元の値）
    buildCondition() {
        const c = this.condition;
        const key = this.jigyoKey || {};
        return {
            jujiJigyoNo: key.jujiJigyoNo,
            jujiBasyoNo: key.jujiBasyoNo,
            jisiNendo: key.jisiNendo,
            uketukeNoFrom: c.uketukeNoFrom === '' ? null : Number(c.uketukeNoFrom),
            uketukeNoTo: c.uketukeNoTo === '' ? null : Number(c.uketukeNoTo),
            torokuNoFrom: c.torokuNoFrom,
            torokuNoTo: c.torokuNoTo,
            shibuCodeFrom: c.shibuCodeFrom,
            shibuCodeTo: c.shibuCodeTo,
            sodaninNoFrom: c.sodaninNoFrom,
            sodaninNoTo: c.sodaninNoTo,
            name: c.name
        };
    }

    // ========== 行選択：選択した応募の ID を返却して閉じる ==========
    handleSelect(event) {
        this.close({ applicationId: event.currentTarget.dataset.id });
    }

    // ========== クリア・閉じる ==========
    handleClearClick() {
        this.condition = emptyCondition();
        this.rows = [];
        this.searched = false;
        this.headerMessages = [];
    }

    handleCloseClick() {
        this.close(undefined);
    }

    // ========== Getter ==========
    get hasHeaderMessages() {
        return this.headerMessages.length > 0;
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    // 検索実行後に 0件の場合のみメッセージを表示する
    get showNotFound() {
        return this.searched && this.rows.length === 0;
    }

    get notFoundMessage() {
        return MSG.NOT_FOUND;
    }
}
