/**
 * JUJ082 応募情報検索 コントローラ
 * 設計書：JUJ082 応募情報検索 検索処理 v7
 *
 * ※ オブジェクト名・項目名は論理名で記載している（API 名確定後に一括置換する）。
 * ※ 従事事業応募は従事事業の主従子オブジェクトのため、参照範囲は従事事業に従う。
 *   SOQL はすべてユーザモードで実行し、支部の条件は付けない。
 * ※ LWC から呼び出すメソッドは内部クラスを引数・戻り値に使用できないため、
 *   引数は JSON 文字列、戻り値は List<Map<String, Object>> とする。
 */
public with sharing class JUJ082Controller {

    // ==================== 定数 ====================
    private static final String TYPE_MEMBER = 'MEMBER'; // 会員
    private static final String TYPE_SODANIN = 'SODANIN'; // 相談員

    // 【要確認】会員の氏名（検索用）：「氏名(姓) + 半角スペース + 氏名(名)」の項目（数式項目を想定）
    @TestVisible
    private static final String MEMBER_NAME_FIELD = '会員__r.氏名_検索用__c';

    // 【要確認 QA-20】メッセージ（{メッセージID, 文言}）
    @TestVisible
    private static final List<String> E_RANGE = new List<String>{ 'SYSTEM-5104', '範囲指定が正しくありません。' };

    // ==================== 1. 検索ボタン押下時 ====================
    // 引数：SearchCondition の JSON 文字列
    // 戻り値：検索結果の行リスト（各行は SearchRow のキーを持つ Map）
    @AuraEnabled
    public static List<Map<String, Object>> search(String conditionJson) {
        try {
            SearchCondition cond = (SearchCondition) JSON.deserialize(conditionJson, SearchCondition.class);

            // (1) 入力チェック：From ＞ To の場合はエラー（画面でもチェック済み。サーバ側は防御用）
            validateRanges(cond);

            // (2) 従事事業の取得。取得できない場合は 0件（エラーとしない）
            Id jigyoId = selectJigyoId(cond.jujiJigyoNo, cond.jujiBasyoNo, cond.jisiNendo);
            if (jigyoId == null) {
                return new List<Map<String, Object>>();
            }

            // (3)〜(7) 抽出・ソート
            List<従事事業応募__c> apps = selectApplications(jigyoId, cond);
            List<Map<String, Object>> rows = new List<Map<String, Object>>();
            for (従事事業応募__c app : apps) {
                rows.add(toMap(toRow(app)));
            }
            return rows;
        } catch (JujiOboException e) {
            AuraHandledException ae = new AuraHandledException(e.getMessage());
            ae.setMessage(e.getMessage());
            throw ae;
        }
    }

    // ==================== (1) 入力チェック ====================
    private static void validateRanges(SearchCondition cond) {
        // 受付番号は数値として比較する
        if (cond.uketukeNoFrom != null && cond.uketukeNoTo != null && cond.uketukeNoFrom > cond.uketukeNoTo) {
            throw error(E_RANGE);
        }
        // 登録番号・支部コード・相談員番号は文字列として比較する
        if (isReversed(cond.torokuNoFrom, cond.torokuNoTo)
            || isReversed(cond.shibuCodeFrom, cond.shibuCodeTo)
            || isReversed(cond.sodaninNoFrom, cond.sodaninNoTo)) {
            throw error(E_RANGE);
        }
    }

    private static Boolean isReversed(String fromValue, String toValue) {
        return String.isNotBlank(fromValue) && String.isNotBlank(toValue) && fromValue.compareTo(toValue) > 0;
    }

    // ==================== Selector ====================
    // (2) 従事事業（3項目のいずれかが未入力の場合はクエリを発行しない）
    private static Id selectJigyoId(String jigyoNo, String basyoNo, String nendo) {
        if (String.isBlank(jigyoNo) || String.isBlank(basyoNo) || String.isBlank(nendo)) {
            return null;
        }
        List<従事事業__c> recs = [
            SELECT Id
            FROM 従事事業__c
            WHERE 従事事業No__c = :jigyoNo
            AND 従事場所__r.従事場所No__c = :basyoNo
            AND 実施年度__c = :nendo
            WITH USER_MODE
            LIMIT 1
        ];
        return recs.isEmpty() ? null : recs[0].Id;
    }

    // (3)〜(7) 従事事業応募の抽出
    private static List<従事事業応募__c> selectApplications(Id jigyoId, SearchCondition cond) {
        Map<String, Object> binds = new Map<String, Object>{ 'jigyoId' => jigyoId };
        List<String> wheres = new List<String>();

        // ② 従事事業キー抽出条件（固定）
        wheres.add('従事事業__c = :jigyoId');

        // ③ 共通抽出条件（入力時のみ）
        if (cond.uketukeNoFrom != null) {
            wheres.add('受付番号__c >= :uketukeNoFrom');
            binds.put('uketukeNoFrom', cond.uketukeNoFrom);
        }
        if (cond.uketukeNoTo != null) {
            wheres.add('受付番号__c <= :uketukeNoTo');
            binds.put('uketukeNoTo', cond.uketukeNoTo);
        }

        // 氏名（会員・相談員共通の部分一致。「%」「_」は通常の文字として扱う）
        String namePattern = String.isBlank(cond.name) ? null : '%' + escapeLike(cond.name) + '%';
        if (namePattern != null) {
            binds.put('namePattern', namePattern);
        }

        // ④ 会員抽出条件
        List<String> memberConds = new List<String>{ '会員__c != null' };
        addRange(memberConds, binds, '会員__r.登録番号__c', 'torokuNo', cond.torokuNoFrom, cond.torokuNoTo);
        addRange(memberConds, binds, '会員__r.事務所__r.支部コード__c', 'shibuCode', cond.shibuCodeFrom, cond.shibuCodeTo);
        if (namePattern != null) {
            memberConds.add(MEMBER_NAME_FIELD + ' LIKE :namePattern');
        }

        // ⑤ 相談員抽出条件
        List<String> sodaninConds = new List<String>{ '相談員__c != null' };
        addRange(sodaninConds, binds, '相談員__r.相談員番号__c', 'sodaninNo', cond.sodaninNoFrom, cond.sodaninNoTo);
        if (namePattern != null) {
            sodaninConds.add('相談員__r.氏名__c LIKE :namePattern');
        }

        // (3) 検索対象判定・⑥ 抽出条件の結合
        Boolean memberSide = isEntered(cond.torokuNoFrom, cond.torokuNoTo)
            || isEntered(cond.shibuCodeFrom, cond.shibuCodeTo);
        Boolean sodaninSide = isEntered(cond.sodaninNoFrom, cond.sodaninNoTo);
        String memberWhere = '(' + String.join(memberConds, ' AND ') + ')';
        String sodaninWhere = '(' + String.join(sodaninConds, ' AND ') + ')';
        if (memberSide && !sodaninSide) {
            wheres.add(memberWhere); // a. 会員のみ
        } else if (sodaninSide && !memberSide) {
            wheres.add(sodaninWhere); // b. 相談員のみ
        } else {
            wheres.add('(' + memberWhere + ' OR ' + sodaninWhere + ')'); // c. 両方
        }

        // (5) 取得項目・(6) ソート順・(7) 取得件数（上限なし）
        String soql =
            'SELECT Id, 受付番号__c, 会員__c, 会員__r.登録番号__c, 会員__r.Name,' +
            ' 会員__r.事務所__r.支部コード__c, 会員__r.事務所__r.支部名__c,' +
            ' 相談員__c, 相談員__r.相談員番号__c, 相談員__r.氏名__c' +
            ' FROM 従事事業応募__c' +
            ' WHERE ' + String.join(wheres, ' AND ') +
            // 【要確認】ソート順一覧（未提供）。暫定：受付番号の昇順
            ' ORDER BY 受付番号__c ASC NULLS LAST, Id ASC';
        return Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);
    }

    // 範囲条件を追加する（入力されている側のみ）
    private static void addRange(
        List<String> conds, Map<String, Object> binds, String field, String bindName, String fromValue, String toValue
    ) {
        if (String.isNotBlank(fromValue)) {
            conds.add(field + ' >= :' + bindName + 'From');
            binds.put(bindName + 'From', fromValue);
        }
        if (String.isNotBlank(toValue)) {
            conds.add(field + ' <= :' + bindName + 'To');
            binds.put(bindName + 'To', toValue);
        }
    }

    private static Boolean isEntered(String fromValue, String toValue) {
        return String.isNotBlank(fromValue) || String.isNotBlank(toValue);
    }

    // LIKE の特殊文字（\ % _）をエスケープする
    @TestVisible
    private static String escapeLike(String value) {
        return value.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_');
    }

    // ==================== 変換 ====================
    // 【要確認】検索結果項目一覧（未提供）。暫定の取得項目
    private static SearchRow toRow(従事事業応募__c app) {
        SearchRow row = new SearchRow();
        row.applicationId = app.Id;
        row.uketukeNo = app.受付番号__c;
        if (app.会員__c != null) {
            row.jujishaType = TYPE_MEMBER;
            row.jujishaNo = app.会員__r.登録番号__c;
            row.name = app.会員__r.Name;
            row.shibuCode = app.会員__r.事務所__r?.支部コード__c;
            row.shibuName = app.会員__r.事務所__r?.支部名__c;
        } else {
            // 相談員の場合、支部コード・支部名は空白
            row.jujishaType = TYPE_SODANIN;
            row.jujishaNo = app.相談員__r?.相談員番号__c;
            row.name = app.相談員__r?.氏名__c;
        }
        return row;
    }

    private static Map<String, Object> toMap(Object dto) {
        return (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(dto));
    }

    // ==================== 例外 ====================
    public class JujiOboException extends Exception {
        public String messageId;
    }

    private static JujiOboException error(List<String> msg) {
        JujiOboException e = new JujiOboException(msg[1]);
        e.messageId = msg[0];
        return e;
    }

    // ==================== DTO（クラス内部でのみ使用） ====================
    // 検索条件
    public class SearchCondition {
        public String jujiJigyoNo;
        public String jujiBasyoNo;
        public String jisiNendo;
        public Decimal uketukeNoFrom;
        public Decimal uketukeNoTo;
        public String torokuNoFrom;
        public String torokuNoTo;
        public String shibuCodeFrom;
        public String shibuCodeTo;
        public String sodaninNoFrom;
        public String sodaninNoTo;
        public String name;
    }

    // 検索結果の1行
    public class SearchRow {
        public Id applicationId;
        public Decimal uketukeNo;
        public String jujishaType;
        public String jujishaNo; // 登録番号 または 相談員番号
        public String name;
        public String shibuCode;
        public String shibuName;
    }
}
